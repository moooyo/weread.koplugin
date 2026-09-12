-- Durable chapter sources and publication receipts. Large bodies, CSS, scans,
-- and assets stay on disk; SQLite owns only immutable file manifests.
local Crypto = require("weread.lib.crypto")
local Content = require("weread.lib.content")

local Store = {}
Store.__index = Store
Store.SOURCE_VERSION = 1

local sequence = 0
local MAX_MANIFEST_BYTES = 8 * 1024 * 1024

local function close(value)
    if value then pcall(function() value:close() end) end
end

local function scalar(value, limit)
    if type(value) ~= "string" and type(value) ~= "number" then return nil end
    value = tostring(value)
    if #value > (limit or 4096) or value:find("%z") then return nil end
    return value
end

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function valid_key(key)
    return type(key) == "string" and #key == 64 and key:match("^[a-f0-9]+$")
end

local function settings_value(settings, key, default)
    if type(settings.get) == "function" then return settings:get(key, default) end
    local value = settings[key]
    if value == nil then return default end
    return value
end

local function account_key(settings, book_id)
    local account = settings_value(settings, "account", {})
    local user_vid = type(account) == "table" and scalar(account.user_vid, 1024)
    if user_vid and user_vid ~= "" then
        return Crypto.sha256_hex("weread-download-account:" .. user_vid):sub(1, 20)
    end
    local api_key = settings_value(settings, "api_key", "")
    if type(api_key) == "string" and api_key ~= "" then
        return Crypto.sha256_hex("weread-download-api:" .. api_key):sub(1, 20)
    end
    -- Anonymous/offline fixtures remain book-scoped. Cookies never determine
    -- identity: rotating a session must not invalidate an account's sources.
    return Crypto.sha256_hex("weread-download-anonymous:" .. book_id):sub(1, 20)
end

local function normalize(path, cwd)
    if type(path) ~= "string" or path == "" or path:find("[%z\r\n]") then
        return nil, "invalid file path"
    end
    path = path:gsub("\\", "/")
    if not path:match("^/") and not path:match("^%a:/") then
        path = cwd:gsub("\\", "/") .. "/" .. path
    end
    local prefix = path:match("^%a:") or ""
    local parts = {}
    for part in path:sub(#prefix + 1):gmatch("[^/]+") do
        if part == ".." then return nil, "parent path traversal is forbidden" end
        if part ~= "." then parts[#parts + 1] = part end
    end
    return prefix .. "/" .. table.concat(parts, "/")
end

local function inside(path, root)
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function walk_path(path, callback)
    local prefix = path:match("^%a:") or ""
    for part in path:sub(#prefix + 1):gmatch("[^/]+") do
        prefix = prefix .. "/" .. part
        local ok, err = callback(prefix)
        if not ok then return nil, err end
    end
    return true
end

function Store:_safePath(path, root)
    local normalized, err = normalize(path, self.cwd)
    if not normalized then return nil, err end
    if not inside(normalized, root or self.root) then
        return nil, "file path is outside the download store"
    end
    local safe, path_err = walk_path(normalized, function(part)
        -- The configured book root may pass through a platform alias such as
        -- /sdcard. Trust directory links at that boundary and above it, but
        -- never follow links introduced inside the plugin's stored artifacts.
        local trusted = inside(self.book_dir, part)
        local attrs = trusted and self.lfs.attributes(part) or self.lfs.symlinkattributes(part)
        if attrs and trusted and attrs.mode ~= "directory" then
            return nil, "configured download root is not a directory"
        elseif attrs and attrs.mode == "link" then
            return nil, "symbolic links are not allowed in download store paths"
        end
        return true
    end)
    return safe and normalized or nil, path_err
end

function Store:_mkdir(path)
    local normalized, err = normalize(path, self.cwd)
    if not normalized then return nil, err end
    return walk_path(normalized, function(part)
        local trusted = self.book_dir and inside(self.book_dir, part)
        local attrs = trusted and self.lfs.attributes(part) or self.lfs.symlinkattributes(part)
        if attrs then
            if attrs.mode ~= "directory" then return nil, "invalid download directory: " .. part end
            return true
        end
        return self.lfs.mkdir(part)
    end)
end

-- Acquisition children use only filesystem operations. Loading this handle
-- does not load SQLite or open a database that another fork could inherit.
function Store:newFiles(settings, book)
    settings, book = settings or {}, book or {}
    local book_id = scalar(book.book_id or book.bookId, 1024)
    if not book_id or book_id == "" then return nil, "book id required" end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or type(lfs.symlinkattributes) ~= "function" then
        return nil, "filesystem attributes are unavailable"
    end
    local instance = setmetatable({ settings = settings, book = book, book_id = book_id,
        lfs = lfs, cwd = lfs.currentdir(), statements = {}, files_only = true }, self)
    local book_dir, path_err = normalize(Content.book_resolved_dir(settings, book_id, book), instance.cwd)
    if not book_dir then return nil, path_err end
    instance.book_dir = book_dir
    instance.account_key = account_key(settings, book_id)
    instance.root = book_dir .. "/.weread-jobs/" .. instance.account_key
    instance.database_path = instance.root .. "/cache.db"
    local made, mkdir_err = instance:_mkdir(instance.root .. "/attempts")
    if not made then return nil, mkdir_err end
    return instance
end

function Store:new(settings, book)
    local instance, create_err = self:newFiles(settings, book)
    if not instance then return nil, create_err end
    local ok_json, json = pcall(require, "json")
    if not ok_json then ok_json, json = pcall(require, "rapidjson") end
    if not ok_json then instance:close(); return nil, "JSON module is unavailable" end
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 then instance:close(); return nil, "SQLite module is unavailable" end
    instance.json = json
    local safe_db, db_path_err = instance:_safePath(instance.database_path)
    if not safe_db then instance:close(); return nil, db_path_err end
    local opened, db = pcall(SQ3.open, safe_db)
    if not opened or not db then instance:close(); return nil, tostring(db or "could not open download database") end
    instance.db = db
    instance.files_only = nil
    local initialized, schema_err = pcall(function()
        db:exec("PRAGMA busy_timeout=1000")
        db:exec("PRAGMA journal_mode=WAL")
        db:exec("PRAGMA synchronous=FULL")
        db:exec([[
            CREATE TABLE IF NOT EXISTS download_cache (
                kind TEXT NOT NULL,
                cache_key TEXT NOT NULL,
                payload TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY(kind, cache_key)
            ) WITHOUT ROWID
        ]])
    end)
    if not initialized then instance:close(); return nil, tostring(schema_err) end
    return instance
end

function Store:_statement(name, query)
    if not self.db then error("download store is closed") end
    local statement = self.statements[name]
    if not statement then
        statement = self.db:prepare(query)
        self.statements[name] = statement
    end
    return statement:reset()
end

function Store:_get(kind, key)
    if not valid_key(key) then return nil, "invalid cache key" end
    local statement
    local ok, result = pcall(function()
        statement = self:_statement("get", "SELECT payload FROM download_cache WHERE kind=? AND cache_key=?")
        local row = statement:bind(kind, key):step()
        if not row then return nil end
        local value = self.json.decode(row[1])
        if type(value) ~= "table" then error("invalid download manifest") end
        return value
    end)
    -- A cached SELECT left on its first row retains a read transaction and
    -- can prevent a later write after another connection commits.
    if statement then pcall(function() statement:reset() end) end
    return ok and result or nil, not ok and tostring(result) or nil
end

function Store:_put(kind, key, value)
    if not valid_key(key) then return nil, "invalid cache key" end
    local statement
    local ok, err = pcall(function()
        local payload = self.json.encode(value)
        if type(payload) ~= "string" or #payload > MAX_MANIFEST_BYTES then
            error("download manifest exceeds its metadata budget")
        end
        statement = self:_statement("put", [[INSERT INTO download_cache(kind,cache_key,payload,updated_at)
            VALUES(?,?,?,?) ON CONFLICT(kind,cache_key) DO UPDATE SET
            payload=excluded.payload,updated_at=excluded.updated_at]])
        statement:bind(kind, key, payload, os.time()):step()
    end)
    -- Reset even after a failed step, so the next operation does not inherit
    -- an old SQLite error from a reusable prepared statement.
    if statement then pcall(function() statement:reset() end) end
    return ok and true or nil, not ok and tostring(err) or nil
end

-- Only stable, bounded source fields enter the identity. Runtime reader
-- parameters, cookies, downloaded bodies, and catalog tables are excluded.
function Store:chapterKey(chapter, image_enabled)
    chapter = chapter or {}
    local uid = scalar(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid, 1024)
    if not uid or uid == "" then return nil, "chapter UID required" end
    local fields = { tostring(Store.SOURCE_VERSION), self.account_key, self.book_id, uid,
        image_enabled and "images" or "text" }
    for _, source in ipairs({ self.book, chapter }) do
        for _, name in ipairs({ "revision", "updateTime", "synckey", "wordCount", "tar", "format", "type" }) do
            local value = scalar(source[name]) or ""
            fields[#fields + 1] = tostring(#value) .. ":" .. value
        end
    end
    return Crypto.sha256_hex(table.concat(fields, "\n"))
end

function Store:newWorkspace(key)
    if self.closed or (not self.db and not self.files_only) then return nil, "download store is closed" end
    if not valid_key(key) then return nil, "invalid cache key" end
    local parent = self.root .. "/attempts/" .. key
    local made, err = self:_mkdir(parent)
    if not made then return nil, err end
    for _ = 1, 10 do
        sequence = sequence + 1
        local path = string.format("%s/attempt-%d-%d-%d", parent,
            os.time(), math.random(100000, 999999), sequence)
        if not self.lfs.symlinkattributes(path) then
            local created = self.lfs.mkdir(path)
            if created then
                local incoming_dir, asset_dir = path .. "/incoming", path .. "/images"
                local incoming_ok, incoming_err = self:_mkdir(incoming_dir)
                if not incoming_ok then return nil, incoming_err end
                local assets_ok, assets_err = self:_mkdir(asset_dir)
                if not assets_ok then return nil, assets_err end
                return { path = path, incoming_dir = incoming_dir, asset_dir = asset_dir }
            end
        end
    end
    return nil, "could not create a private download workspace"
end

function Store:writeText(path, data)
    if self.closed or (not self.db and not self.files_only) then return nil, "download store is closed" end
    if type(data) ~= "string" then return nil, "text content must be a string" end
    local target, path_err = self:_safePath(path)
    if not target then return nil, path_err end
    if not inside(target, self.root .. "/attempts") then return nil, "text must belong to an attempt" end
    -- Source files are immutable. Reusing a path could silently alter a
    -- committed bundle, so retries always allocate a new attempt directory.
    if self.lfs.symlinkattributes(target) then return nil, "source file already exists" end
    sequence = sequence + 1
    local temporary = target .. ".part-" .. tostring(sequence) .. "-" .. tostring(math.random(100000, 999999))
    local safe_temp, temp_err = self:_safePath(temporary)
    if not safe_temp then return nil, temp_err end
    if self.lfs.symlinkattributes(temporary) then return nil, "temporary file already exists" end
    local file, open_err = io.open(temporary, "wb")
    if not file then return nil, open_err end
    local ok, err = pcall(function()
        assert(file:write(data))
        assert(file:flush())
        assert(file:close())
        file = nil
        assert(os.rename(temporary, target))
    end)
    close(file)
    if not ok then os.remove(temporary); return nil, tostring(err) end
    return true
end

function Store:_file(path, expected_size, root, allow_empty)
    local safe, path_err = self:_safePath(path, root)
    if not safe then return nil, nil, path_err end
    local attrs = self.lfs.attributes(safe)
    if not attrs or attrs.mode ~= "file" or not finite(attrs.size)
        or attrs.size < (allow_empty and 0 or 1) then
        return nil, nil, "missing or empty download file"
    end
    if expected_size ~= nil and (not finite(expected_size) or attrs.size ~= expected_size) then
        return nil, nil, "download file size changed"
    end
    return safe, attrs.size
end

-- Moving a book directory also moves its database. Rebase only absolute paths
-- inside the recorded storage root, then apply ordinary path and file checks
-- at the new location. Never access the former filesystem location.
function Store:_relocate(path, previous_root, current_root)
    local function absolute(value)
        return type(value) == "string" and (value:match("^/") or value:match("^%a:[/\\]"))
    end
    if not absolute(previous_root) or not absolute(path) then
        return nil, "missing or invalid previous storage root"
    end
    local old_root, root_err = normalize(previous_root, self.cwd)
    if not old_root then return nil, root_err end
    local original, path_err = normalize(path, self.cwd)
    if not original then return nil, path_err end
    if not inside(original, old_root) or original == old_root then
        return nil, "stored file path is outside its original root"
    end
    return current_root .. original:sub(#old_root + 1)
end

function Store:_chapter(bundle, reading)
    if type(bundle) ~= "table" then return nil, "invalid chapter bundle" end
    if reading and not bundle.storage_root then return nil, "source storage root is missing" end
    local result = { version = Store.SOURCE_VERSION, storage_root = self.root,
        resources_complete = bundle.resources_complete ~= false, assets = {} }
    for _, prefix in ipairs({ "xhtml", "css", "scan", "annotation" }) do
        local path = bundle[prefix .. "_path"]
        if prefix == "xhtml" or path ~= nil then
            if reading then
                local relocated, relocation_err = self:_relocate(path, bundle.storage_root, self.root)
                if not relocated then return nil, relocation_err end
                path = relocated
            end
            local size = bundle[prefix .. "_size"]
            if reading and not finite(size) then return nil, "missing source size" end
            local safe, bytes, err = self:_file(path, size, self.root, prefix ~= "xhtml")
            if not safe then return nil, err end
            result[prefix .. "_path"], result[prefix .. "_size"] = safe, bytes
        end
    end
    if bundle.assets ~= nil and type(bundle.assets) ~= "table" then return nil, "invalid asset list" end
    for _, asset in ipairs(bundle.assets or {}) do
        if type(asset) ~= "table" or (reading and not finite(asset.size)) then return nil, "invalid asset" end
        local asset_path = asset.path
        if reading then
            local relocated, relocation_err = self:_relocate(asset_path, bundle.storage_root, self.root)
            if not relocated then return nil, relocation_err end
            asset_path = relocated
        end
        local path, bytes, err = self:_file(asset_path, asset.size)
        if not path then return nil, err end
        local href = scalar(asset.href)
        if not href or href == "" or href:sub(1, 1) == "/" or href:find("\\", 1, true)
            or href:find(":", 1, true) then return nil, "invalid asset reference" end
        for segment in href:gmatch("[^/]+") do
            if segment == ".." or segment == "." then return nil, "invalid asset reference" end
        end
        result.assets[#result.assets + 1] = { path = path, size = bytes,
            href = href, media_type = scalar(asset.media_type, 256), store = asset.store == true }
    end
    result.chapter_uid = scalar(bundle.chapter_uid, 1024)
    result.content_format = scalar(bundle.content_format, 128)
    result.annotation_raw_text = bundle.annotation_raw_text == true
    return result
end

function Store:getChapter(key, options)
    local bundle, err = self:_get("chapter", key)
    if not bundle then return nil, err end
    if bundle.version ~= Store.SOURCE_VERSION then return nil, "source version changed" end
    if bundle.resources_complete == false and not (type(options) == "table" and options.allow_incomplete) then
        return nil, "resources incomplete"
    end
    return self:_chapter(bundle, true)
end

function Store:putChapter(key, bundle)
    local value, err = self:_chapter(bundle, false)
    if not value then return nil, err end
    return self:_put("chapter", key, value)
end

function Store:_publication(publication, reading)
    if type(publication) ~= "table" then return nil, "invalid publication" end
    if reading and not finite(publication.size) then return nil, "missing publication size" end
    local publication_path = publication.path
    if reading then
        local relocated, relocation_err = self:_relocate(publication_path, publication.cache_dir, self.book_dir)
        if not relocated then return nil, relocation_err end
        publication_path = relocated
    end
    local path, size, err = self:_file(publication_path, publication.size, self.book_dir)
    if not path then return nil, err end
    local result = { version = 1, path = path, size = size, cache_dir = self.book_dir,
        resources_complete = publication.resources_complete ~= false,
        chapter_paths = {}, chapter_sizes = {}, selected_uids = {}, failed_uids = {}, footnote_stats = {} }
    if not reading and publication.cache_dir ~= nil then
        local dir, dir_err = self:_safePath(publication.cache_dir, self.book_dir)
        if not dir then return nil, dir_err end
        if dir ~= self.book_dir then return nil, "publication cache directory must be its book root" end
    end
    if publication.chapter_paths ~= nil and type(publication.chapter_paths) ~= "table" then
        return nil, "invalid chapter publication paths"
    end
    for uid, chapter_path in pairs(publication.chapter_paths or {}) do
        uid = scalar(uid, 1024)
        if not uid then return nil, "invalid publication chapter UID" end
        local expected = type(publication.chapter_sizes) == "table" and publication.chapter_sizes[uid] or nil
        if reading and not finite(expected) then return nil, "missing chapter publication size" end
        if reading then
            local relocated, relocation_err = self:_relocate(chapter_path, publication.cache_dir, self.book_dir)
            if not relocated then return nil, relocation_err end
            chapter_path = relocated
        end
        local safe, bytes, file_err = self:_file(chapter_path, expected, self.book_dir)
        if not safe then return nil, file_err end
        result.chapter_paths[uid], result.chapter_sizes[uid] = safe, bytes
    end
    for _, name in ipairs({ "selected_uids", "failed_uids" }) do
        if publication[name] ~= nil and type(publication[name]) ~= "table" then return nil, "invalid publication UIDs" end
        for _, uid in ipairs(publication[name] or {}) do
            local value = scalar(uid, 1024)
            if not value then return nil, "invalid publication chapter UID" end
            result[name][#result[name] + 1] = value
        end
    end
    for name, value in pairs(type(publication.footnote_stats) == "table" and publication.footnote_stats or {}) do
        local key = scalar(name, 128)
        if key and finite(value) then result.footnote_stats[key] = value end
    end
    local reader_url = scalar(publication.reader_url, 2048)
    if reader_url and (reader_url:match("^https://weread%.qq%.com/web/reader/[%w_/%-]+$")
        or reader_url:match("^https://weread%.qq%.com/reader/[%w_/%-]+$")) then
        result.reader_url = reader_url
    end
    return result
end

function Store:getPublication(key)
    local value, err = self:_get("publication", key)
    if not value then return nil, err end
    if value.version ~= 1 then return nil, "publication version changed" end
    return self:_publication(value, true)
end

function Store:putPublication(key, value)
    local publication, err = self:_publication(value, false)
    if not publication then return nil, err end
    return self:_put("publication", key, publication)
end

-- Cleanup is explicit so opening a second store cannot remove a running
-- worker's attempt. Call only while this book's coordinator is idle.
function Store:cleanupStale(max_age)
    if not self.db then return nil, "download store is closed" end
    max_age = max_age == nil and 86400 or max_age
    if not finite(max_age) or max_age < 0 then return nil, "invalid cleanup age" end
    local referenced = {}
    local statement
    local ok, err = pcall(function()
        statement = self:_statement("all_references", [[SELECT kind,payload FROM download_cache
            WHERE kind IN ('chapter','publication')]])
        local row = statement:step()
        while row do
            local kind, bundle = row[1], self.json.decode(row[2])
            if type(bundle) ~= "table" then error("invalid download manifest prevents cleanup") end
            local function retain(path, publication)
                if path == nil then return end
                if publication then
                    path = assert(self:_relocate(path, bundle.cache_dir, self.book_dir))
                elseif bundle.storage_root then
                    path = assert(self:_relocate(path, bundle.storage_root, self.root))
                end
                local safe = assert(self:_safePath(path, publication and self.book_dir or self.root))
                local attempts = self.root .. "/attempts"
                if inside(safe, attempts) then
                    local key, name = safe:sub(#attempts + 2):match(
                        "^([a-f0-9]+)/(attempt%-%d+%-%d+%-%d+)/")
                    if not valid_key(key) or not name then error("unrecognized source path prevents cleanup") end
                    referenced[attempts .. "/" .. key .. "/" .. name] = true
                elseif not publication then
                    error("unrecognized source path prevents cleanup")
                end
            end
            -- A damaged but committed file remains referenced until a new
            -- artifact replaces its receipt. Cleanup never doubles as cache
            -- invalidation, and legacy publications outside attempts survive.
            if kind == "publication" then
                retain(bundle.path, true)
                for _, path in pairs(bundle.chapter_paths or {}) do retain(path, true) end
            else
                retain(bundle.xhtml_path); retain(bundle.css_path); retain(bundle.scan_path); retain(bundle.annotation_path)
                for _, asset in ipairs(bundle.assets or {}) do retain(asset.path) end
            end
            row = statement:step()
        end
    end)
    if statement then pcall(function() statement:reset() end) end
    if not ok then return nil, tostring(err) end
    local removed = 0
    local function remove_tree(path)
        local safe = assert(self:_safePath(path))
        local attrs = self.lfs.symlinkattributes(safe)
        if not attrs then return end
        if attrs.mode == "directory" then
            for name in self.lfs.dir(safe) do
                if name ~= "." and name ~= ".." then remove_tree(safe .. "/" .. name) end
            end
            assert(self.lfs.rmdir(safe))
        else
            assert(os.remove(safe))
        end
    end
    local cleaned, clean_err = pcall(function()
        local attempts = assert(self:_safePath(self.root .. "/attempts"))
        for key in self.lfs.dir(attempts) do
            if valid_key(key) then
                local parent = assert(self:_safePath(attempts .. "/" .. key))
                local attrs = self.lfs.symlinkattributes(parent)
                if attrs and attrs.mode == "directory" then
                    for name in self.lfs.dir(parent) do
                        local timestamp = tonumber(name:match("^attempt%-(%d+)%-%d+%-%d+$"))
                        local path = parent .. "/" .. name
                        if timestamp and os.time() - timestamp >= max_age and not referenced[path] then
                            remove_tree(path)
                            removed = removed + 1
                        end
                    end
                end
            end
        end
    end)
    return cleaned and removed or nil, not cleaned and tostring(clean_err) or nil
end

function Store:close()
    for _, statement in pairs(self.statements or {}) do close(statement) end
    self.statements = {}
    close(self.db)
    self.db = nil
    self.closed = true
end

return Store
