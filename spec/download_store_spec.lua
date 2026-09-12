package.path = "./?.lua;./?/init.lua;" .. package.path

-- Reuse the real SQLite declarations and deterministic test-only table codec.
local helper = require("spec.helpers.annotation_test_store")
local ffi = require("ffi")
local loaded, sqlite = pcall(ffi.load, "sqlite3")
if not loaded then sqlite = ffi.load("libsqlite3.so.0") end
local open_statements = 0
local connections = 0

package.preload["lua-ljsqlite3/init"] = function()
    return { open = function(path)
        local pointer = ffi.new("sqlite3 *[1]")
        assert(sqlite.sqlite3_open(path, pointer) == 0)
        connections = connections + 1
        local db = { pointer = pointer[0] }
        local function check(code)
            if code ~= 0 and code ~= 100 and code ~= 101 then
                error(ffi.string(sqlite.sqlite3_errmsg(db.pointer)))
            end
            return code
        end
        function db:exec(query) check(sqlite.sqlite3_exec(self.pointer, query, nil, nil, nil)) end
        function db:close()
            check(sqlite.sqlite3_close(self.pointer))
            connections = connections - 1
        end
        function db.prepare(connection, query)
            local statement_pointer = ffi.new("sqlite3_stmt *[1]")
            check(sqlite.sqlite3_prepare_v2(connection.pointer, query, -1, statement_pointer, nil))
            open_statements = open_statements + 1
            local statement = { pointer = statement_pointer[0], values = {} }
            function statement:reset() check(sqlite.sqlite3_reset(self.pointer)); return self end
            function statement:bind(...)
                self.values = { ... }
                for index, value in ipairs(self.values) do
                    self.values[index] = tostring(value)
                    check(sqlite.sqlite3_bind_text(self.pointer, index, self.values[index], -1,
                        ffi.cast("void*", -1)))
                end
                return self
            end
            function statement:step()
                if check(sqlite.sqlite3_step(self.pointer)) ~= 100 then return nil end
                local row = {}
                for index = 0, sqlite.sqlite3_column_count(self.pointer) - 1 do
                    local value = sqlite.sqlite3_column_text(self.pointer, index)
                    row[index + 1] = value ~= nil and ffi.string(value) or nil
                end
                return row
            end
            function statement:close()
                check(sqlite.sqlite3_finalize(self.pointer))
                open_statements = open_statements - 1
            end
            return statement
        end
        return db
    end }
end

local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
local function command_output(command)
    local process = assert(io.popen(command))
    local output = process:read("*a")
    process:close()
    return output
end
local function successful(command)
    local code = os.execute(command)
    return code == 0 or code == true
end

-- KOReader bundles LFS. A small shell-backed adapter keeps this standalone
-- regression runnable under the bare remote LuaJIT used by the repository.
local function attributes(path, follow)
    local value = command_output("stat " .. (follow and "-L " or "")
        .. "-c '%F:%s' -- " .. quote(path) .. " 2>/dev/null")
    local mode, size = value:match("^([^:]+):(%d+)")
    if not mode then return nil end
    if mode == "directory" then mode = "directory"
    elseif mode == "symbolic link" then mode = "link"
    elseif mode:find("regular", 1, true) then mode = "file" end
    return { mode = mode, size = tonumber(size) }
end
local lfs = {
    currentdir = function() return command_output("pwd"):gsub("\n$", "") end,
    attributes = function(path) return attributes(path, true) end,
    symlinkattributes = function(path) return attributes(path, false) end,
    mkdir = function(path) return successful("mkdir -- " .. quote(path)) end,
    rmdir = function(path) return successful("rmdir -- " .. quote(path)) end,
    dir = function(path)
        local entries = command_output("find " .. quote(path)
            .. " -mindepth 1 -maxdepth 1 -printf '%f\\n'")
        return entries:gmatch("[^\n]+")
    end,
}
package.preload["libs/libkoreader-lfs"] = function() return lfs end

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end
local function write(path, content)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content)); assert(file:close())
end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"); file:close()
    return content
end

local Store = require("weread.lib.download_store")
local Crypto = require("weread.lib.crypto")
local tmp = os.tmpname()
os.remove(tmp)
assert(lfs.mkdir(tmp))
local account = { user_vid = "test-user-1001" }
local api_key = ""
local settings = { cache_dir = tmp, get = function(_, key, default)
    if key == "account" then return account end
    if key == "api_key" then return api_key end
    if key == "cookies" then return { wr_vid = "rotating-cookie-secret" } end
    return default
end }
local book = { book_id = "test-book", updateTime = 10, cookies = "never-persist-book-secret" }
local connections_before_files = connections
local files = assert(Store:newFiles(settings, { book_id = "files-only" }))
local files_key = Crypto.sha256_hex("files-only-chapter")
local files_workspace = assert(files:newWorkspace(files_key))
local files_source = files_workspace.path .. "/source.xhtml"
assert(files:writeText(files_source, "<p>files only</p>"))
expect(files.db == nil and connections == connections_before_files and not lfs.attributes(files.database_path),
    "filesystem acquisition opened or created a SQLite database")
expect(read(files_source) == "<p>files only</p>", "filesystem acquisition did not preserve source text")
files:close(); files:close()
expect(not files:newWorkspace(files_key) and not files:writeText(files_workspace.path .. "/late.xhtml", "late"),
    "closed filesystem acquisition handle remained writable")
local store = assert(Store:new(settings, book))
local chapter = { chapterUid = 1, title = "Repeated title", wordCount = 500,
    updateTime = 20, synckey = "21", tar = "/images/revision-one.tar" }
local key = assert(store:chapterKey(chapter, true))
expect(#key == 64, "chapter key must be a bounded hash")
expect(not store.root:find("test-user", 1, true), "account path leaked the user VID")
expect(not store.root:find(".weread-download-", 1, true), "durable workspace matches disposable cleanup")
expect(lfs.attributes(store.database_path).mode == "file", "store did not create its database")
expect(store:getChapter(key) == nil, "uncommitted chapter was reused")
local same_title = { chapterUid = 2, title = chapter.title, wordCount = 500, updateTime = 20 }
expect(store:chapterKey(same_title, true) ~= key, "same-title chapters share source identity")
book.psvts, book.cookies, book._content_format = "new-session", "new-cookie", "epub"
book.chapters = { { giant_nested_field = string.rep("unused", 10000) } }
expect(store:chapterKey(chapter, true) == key, "runtime data changed source identity")
expect(store:chapterKey(chapter, false) ~= key, "image option did not change source identity")
chapter.updateTime = 21
expect(store:chapterKey(chapter, true) ~= key, "source revision did not invalidate cache")
chapter.updateTime = 20
book.updateTime = 11
expect(store:chapterKey(chapter, true) ~= key, "book revision did not invalidate cache")
book.updateTime = 10

local workspace = assert(store:newWorkspace(key))
local bundle = { xhtml_path = workspace.path .. "/source.xhtml",
    css_path = workspace.path .. "/source.css", scan_path = workspace.path .. "/scan.json",
    chapter_uid = "1", content_format = "epub", assets = {},
    auth = "must-not-be-serialized", xhtml = "must-not-be-stored-in-sqlite" }
assert(store:writeText(bundle.xhtml_path, "<p>chapter body</p>"))
assert(store:writeText(bundle.css_path, ""))
assert(store:writeText(bundle.scan_path, "{}"))
local image_path = workspace.asset_dir .. "/image.jpg"
write(image_path, "image-bytes")
bundle.assets[1] = { path = image_path, href = "images/image.jpg", media_type = "image/jpeg",
    size = 11, store = true, data = "must-not-be-serialized" }
expect(store:putChapter(key, bundle), "valid bundle was not committed")
expect(not store:writeText(bundle.xhtml_path, "overwrite"), "committed source was overwritten")
local restored = assert(store:getChapter(key))
expect(restored.xhtml_size == 19 and restored.assets[1].size == 11, "file sizes were not recorded")
expect(restored.css_size == 0 and restored.assets[1].store, "empty CSS or stored image metadata was lost")
expect(restored.auth == nil and restored.xhtml == nil and restored.assets[1].data == nil,
    "large or sensitive data entered manifest")
expect(restored.content_format == "epub" and restored.chapter_uid == "1", "source descriptors were lost")
expect(restored.storage_root == store.root, "source manifest did not record its original storage root")
expect(restored.resources_complete == true, "resource completeness did not default to true")
local incomplete_key = Crypto.sha256_hex("incomplete-chapter-resources")
local incomplete_workspace = assert(store:newWorkspace(incomplete_key))
local incomplete_source = incomplete_workspace.path .. "/source.xhtml"
assert(store:writeText(incomplete_source, "<p>readable text without an image</p>"))
assert(store:putChapter(incomplete_key, { xhtml_path = incomplete_source, chapter_uid = "3",
    resources_complete = false, assets = {} }))
local incomplete, incomplete_err = store:getChapter(incomplete_key)
expect(not incomplete and incomplete_err == "resources incomplete", "incomplete chapter resources were reused")
expect(store:getChapter(incomplete_key, { allow_incomplete = true }).resources_complete == false,
    "assembly could not explicitly read an incomplete but committed chapter")
expect(store:_get("chapter", incomplete_key).resources_complete == false,
    "incomplete chapter flag was not persisted in SQLite")
local legacy_manifest = assert(store:_get("chapter", key))
legacy_manifest.resources_complete = nil
assert(store:_put("chapter", key, legacy_manifest))
expect(store:getChapter(key).resources_complete == true, "legacy chapter completeness did not default to true")
legacy_manifest.storage_root = nil
assert(store:_put("chapter", key, legacy_manifest))
expect(not store:getChapter(key), "legacy source without a storage root was guessed instead of refetched")
assert(store:putChapter(key, bundle))
local original_root = store.root
store:close(); store:close()
expect(open_statements == 0 and connections == 0, "SQLite resources survived idempotent close")
store = assert(Store:new(settings, book))
expect(store.root == original_root and store:getChapter(key), "completed work did not survive restart")
write(image_path, "truncated")
expect(not store:getChapter(key), "truncated asset was reused")
write(image_path, "image-bytes")
os.remove(bundle.scan_path)
expect(not store:getChapter(key), "missing scan was reused")
write(bundle.scan_path, "{}")
write(bundle.xhtml_path, "short")
expect(not store:getChapter(key), "truncated source was reused")
write(bundle.xhtml_path, "<p>chapter body</p>")
expect(store:getChapter(key), "restored valid bundle was not reusable")
store.db:exec([[CREATE TRIGGER fail_write BEFORE INSERT ON download_cache
    BEGIN SELECT RAISE(ABORT, 'injected manifest failure'); END]])
expect(not store:putChapter(key, bundle), "injected SQLite error was swallowed")
expect(store:getChapter(key).xhtml_path == bundle.xhtml_path, "failed SQL commit replaced a valid source")
store.db:exec("DROP TRIGGER fail_write")
expect(store:putChapter(key, bundle), "prepared statement did not recover after a failed write")
local observer = assert(Store:new(settings, book))
expect(observer:getChapter(key), "independent connection could not read committed work")
expect(store:putChapter(key, bundle), "open reader prevented a committing writer")
expect(observer:putChapter(key, bundle), "read statement retained a stale SQLite transaction")
observer:close()

local outside = tmp .. "/outside.xhtml"
write(outside, "outside")
expect(not store:putChapter(key, { xhtml_path = outside }), "outside source path was accepted")
expect(not store:writeText(workspace.path .. "/../escape", "escape"), "parent traversal was accepted")
expect(not store:writeText(store.root .. "-sibling/escape", "escape"), "sibling prefix escaped root")
local symlink = workspace.path .. "/outside-link"
assert(successful("ln -s -- " .. quote(tmp) .. " " .. quote(symlink)))
expect(not store:writeText(symlink .. "/escaped", "escape"), "symlink escaped source root")
expect(not store:putChapter(key, { xhtml_path = symlink .. "/outside.xhtml" }), "symlink source was accepted")
os.remove(symlink)
local invalid_asset = { xhtml_path = bundle.xhtml_path, assets = {
    { path = image_path, href = "images/../escape", size = 11 } } }
expect(not store:putChapter(key, invalid_asset), "archive reference traversal was accepted")
expect(store:getChapter(key).xhtml_path == bundle.xhtml_path, "failed commit replaced valid source")

local publication_key = Crypto.sha256_hex("publication-plan")
local epub = store.book_dir .. "/complete.epub"
local second_epub = store.book_dir .. "/second.epub"
write(epub, "epub-data"); write(second_epub, "second-epub")
expect(store:putPublication(publication_key, { path = epub,
    chapter_paths = { ["1"] = epub, ["2"] = second_epub }, selected_uids = { "1", "2" }, failed_uids = {},
    footnote_stats = { converted = 2 }, reader_url = "https://weread.qq.com/reader/test",
    auth = "publication-auth-secret", annotation_documents = { body = "unbounded metadata" } }),
    "valid publication was not retained")
local publication = assert(store:getPublication(publication_key))
expect(publication.path == epub and publication.chapter_paths["2"] == second_epub,
    "publication receipt lost output paths")
expect(publication.selected_uids[2] == "2" and publication.footnote_stats.converted == 2,
    "publication receipt lost catalog metadata")
expect(publication.auth == nil and publication.annotation_documents == nil,
    "publication receipt retained private or unbounded metadata")
expect(publication.resources_complete == true, "publication resource completeness did not default to true")
local legacy_publication = assert(store:_get("publication", publication_key))
legacy_publication.resources_complete = nil
assert(store:_put("publication", publication_key, legacy_publication))
expect(store:getPublication(publication_key).resources_complete == true,
    "legacy publication completeness did not default to true")
local incomplete_publication_key = Crypto.sha256_hex("incomplete-publication-resources")
assert(store:putPublication(incomplete_publication_key, { path = epub, selected_uids = { "1" },
    resources_complete = false }))
expect(store:getPublication(incomplete_publication_key).resources_complete == false,
    "incomplete publication flag was lost or its readable artifact was rejected")
write(second_epub, "short")
expect(not store:getPublication(publication_key), "partial publication was reused")
write(second_epub, "second-epub")
expect(not store:putPublication(publication_key, { path = outside }), "publication escaped the book root")
expect(store:getPublication(publication_key), "invalid publication commit replaced valid receipt")
store:close()
store = assert(Store:new(settings, book))
expect(store:getPublication(publication_key), "published artifact did not survive a metadata retry")
expect(store:getPublication(incomplete_publication_key).resources_complete == false,
    "incomplete publication state did not survive reopening")
incomplete, incomplete_err = store:getChapter(incomplete_key)
expect(not incomplete and incomplete_err == "resources incomplete", "incomplete chapter was reused after reopening")

local edition_one_key = Crypto.sha256_hex("publication-render-one")
local edition_two_key = Crypto.sha256_hex("publication-render-two")
local edition_one = assert(store:newWorkspace(edition_one_key))
local edition_two = assert(store:newWorkspace(edition_two_key))
local extra_chapter = assert(store:newWorkspace(edition_two_key))
local edition_one_path = edition_one.path .. "/book.epub"
local edition_two_path = edition_two.path .. "/book.epub"
local extra_path = extra_chapter.path .. "/chapter.epub"
write(edition_one_path, "edition-A")
write(edition_two_path, "edition-B")
write(extra_path, "chapter-B")
assert(store:putPublication(edition_one_key, { path = edition_one_path, selected_uids = { "1" },
    reader_url = "https://weread.qq.com/web/reader/test" }))
assert(store:putPublication(edition_two_key, { path = edition_two_path,
    chapter_paths = { ["1"] = edition_two_path, ["2"] = extra_path }, selected_uids = { "1", "2" } }))
local first_receipt = assert(store:getPublication(edition_one_key))
local second_receipt = assert(store:getPublication(edition_two_key))
expect(first_receipt.path ~= second_receipt.path and first_receipt.size == second_receipt.size,
    "equal-size editions did not keep independent publication identities")
expect(read(first_receipt.path) == "edition-A" and read(second_receipt.path) == "edition-B",
    "a new rendering replaced an existing edition")
expect(first_receipt.reader_url == "https://weread.qq.com/web/reader/test",
    "official web reader URL did not survive the publication receipt")
local failed_candidate = assert(store:newWorkspace(edition_two_key))
write(failed_candidate.path .. "/book.epub.part", "incomplete-edition")
write(extra_path, "bad")
expect(not store:getPublication(edition_two_key), "damaged edition was reused")
expect(store:cleanupStale(0) == 1 and not lfs.attributes(failed_candidate.path),
    "failed private render candidate was not cleaned")
expect(lfs.attributes(edition_one.path) and lfs.attributes(edition_two.path)
    and lfs.attributes(extra_chapter.path), "cleanup removed a referenced publication directory")
expect(read(edition_one_path) == "edition-A" and read(extra_path) == "bad",
    "cleanup invalidated a committed receipt before its replacement")
write(extra_path, "chapter-B")
store:close()
store = assert(Store:new(settings, book))
expect(store:getPublication(edition_one_key).path == edition_one_path
    and store:getPublication(edition_two_key).chapter_paths["2"] == extra_path,
    "edition receipts did not survive reopening")

local orphan = assert(store:newWorkspace(key))
assert(store:writeText(orphan.path .. "/partial.xhtml", "partial"))
local retained = assert(store:cleanupStale(0))
expect(retained == 1 and not lfs.attributes(orphan.path), "abandoned attempt was not cleaned")
expect(lfs.attributes(workspace.path) and store:getChapter(key), "cleanup removed a committed source")
expect(lfs.attributes(incomplete_workspace.path) and read(incomplete_source):find("readable text", 1, true),
    "cleanup removed the only committed copy of an incomplete chapter")
assert(store:putChapter(incomplete_key, { xhtml_path = incomplete_source, chapter_uid = "3",
    resources_complete = true, assets = {} }))
expect(store:getChapter(incomplete_key).resources_complete == true,
    "completed resource retry did not make the chapter reusable")
expect(read(epub) == "epub-data", "cleanup removed a published EPUB")
local db_bytes = read(store.database_path)
local wal = io.open(store.database_path .. "-wal", "rb")
if wal then db_bytes = db_bytes .. wal:read("*a"); wal:close() end
expect(not db_bytes:find("must-not", 1, true) and not db_bytes:find("publication-auth-secret", 1, true)
    and not db_bytes:find("rotating-cookie-secret", 1, true), "SQLite persisted secrets or body data")
local previous_book_dir = store.book_dir
store:close()

local moved_book_dir = tmp .. "/moved-book"
assert(os.rename(previous_book_dir, moved_book_dir))
book.cache_dir = moved_book_dir
store = assert(Store:new(settings, book))
local moved_root = store.root
expect(store:chapterKey(chapter, true) == key, "moving a book changed its source identity")
local moved_source = assert(store:getChapter(key))
expect(moved_source.storage_root == moved_root and moved_source.xhtml_path:sub(1, #moved_root) == moved_root,
    "source files were not relocated to the moved book directory")
expect(read(moved_source.xhtml_path) == "<p>chapter body</p>" and read(moved_source.css_path) == ""
    and read(moved_source.scan_path) == "{}" and read(moved_source.assets[1].path) == "image-bytes",
    "moved source, CSS, scan, or asset data was lost")
local moved_publication = assert(store:getPublication(publication_key))
expect(moved_publication.cache_dir == moved_book_dir and moved_publication.path == moved_book_dir .. "/complete.epub"
    and moved_publication.chapter_paths["2"] == moved_book_dir .. "/second.epub",
    "top-level publication receipt was not relocated with the book")
local moved_edition = assert(store:getPublication(edition_two_key))
expect(moved_edition.path:sub(1, #moved_root) == moved_root
    and read(moved_edition.path) == "edition-B" and read(moved_edition.chapter_paths["2"]) == "chapter-B",
    "private edition paths were not relocated with the book")
expect(store:cleanupStale(0) == 0 and store:getChapter(key) and store:getPublication(edition_two_key),
    "cleanup removed committed artifacts after moving their directory")
write(moved_source.assets[1].path, "broken")
expect(not store:getChapter(key), "moved source skipped file size validation")
write(moved_source.assets[1].path, "image-bytes")
local original_manifest = assert(store:_get("chapter", key))
local unsafe_manifest = assert(store:_get("chapter", key))
unsafe_manifest.xhtml_path = unsafe_manifest.storage_root .. "/../escape.xhtml"
assert(store:_put("chapter", key, unsafe_manifest))
expect(not store:getChapter(key), "source relocation accepted parent path traversal")
unsafe_manifest.xhtml_path = unsafe_manifest.storage_root .. "-sibling/source.xhtml"
assert(store:_put("chapter", key, unsafe_manifest))
expect(not store:getChapter(key), "source relocation accepted a sibling root prefix")
assert(store:_put("chapter", key, original_manifest))
local receipt = assert(store:_get("publication", publication_key))
local unsafe_receipt = assert(store:_get("publication", publication_key))
unsafe_receipt.chapter_paths["2"] = receipt.cache_dir .. "/../second.epub"
assert(store:_put("publication", publication_key, unsafe_receipt))
expect(not store:getPublication(publication_key), "publication relocation accepted parent path traversal")
assert(store:_put("publication", publication_key, receipt))
expect(store:getChapter(key) and store:getPublication(publication_key), "restored moved manifests were not reusable")
store:close()

account = { user_vid = "test-user-2002" }
local other = assert(Store:new(settings, book))
expect(other.root ~= moved_root and not other:getChapter(key), "another account reused private sources")
other:close()
account = {}
api_key = "first-api-secret"
local first_api = assert(Store:new(settings, book))
local api_root = first_api.root
expect(not api_root:find(api_key, 1, true), "API credential leaked into paths")
first_api:close()
api_key = "second-api-secret"
local second_api = assert(Store:new(settings, book))
expect(second_api.root ~= api_root, "unidentified API accounts shared sources")
second_api:close()
api_key = ""
local anonymous = assert(Store:new(settings, book))
expect(anonymous.root ~= api_root and anonymous.root ~= original_root, "anonymous state reused account sources")
anonymous:close()

-- User-selected directory aliases are valid storage roots, while links added
-- beneath the book root must still be rejected for both sources and outputs.
local alias_target, alias_root = tmp .. "/alias-target", tmp .. "/alias-root"
assert(lfs.mkdir(alias_target))
assert(successful("ln -s -- " .. quote(alias_target) .. " " .. quote(alias_root)))
local alias_settings = { cache_dir = alias_root, get = settings.get }
local alias_book = { book_id = "aliased-book" }
local alias_store = assert(Store:new(alias_settings, alias_book))
local alias_key = assert(alias_store:chapterKey({ chapterUid = 1 }, true))
local alias_workspace = assert(alias_store:newWorkspace(alias_key))
local alias_source = alias_workspace.path .. "/source.xhtml"
assert(alias_store:writeText(alias_source, "<p>aliased source</p>"))
assert(alias_store:putChapter(alias_key, { xhtml_path = alias_source, chapter_uid = "1" }))
expect(alias_store:getChapter(alias_key) and read(alias_source) == "<p>aliased source</p>",
    "a symbolic link above the book root prevented source persistence")
local alias_epub = alias_store.book_dir .. "/book.epub"
write(alias_epub, "aliased EPUB")
assert(alias_store:putPublication(alias_key, { path = alias_epub, selected_uids = { "1" } }))
expect(alias_store:getPublication(alias_key).path == alias_epub,
    "a symbolic link above the book root prevented publication persistence")
local internal_link = alias_workspace.path .. "/internal-link"
assert(successful("ln -s -- " .. quote(tmp) .. " " .. quote(internal_link)))
expect(not alias_store:writeText(internal_link .. "/escaped-source", "escape"),
    "trusting the configured root also trusted an internal directory link")
expect(not alias_store:putChapter(alias_key, { xhtml_path = internal_link .. "/outside.xhtml" }),
    "source validation followed an internal link below an aliased root")
local linked_epub = alias_store.book_dir .. "/linked.epub"
assert(successful("ln -s -- " .. quote(outside) .. " " .. quote(linked_epub)))
expect(not alias_store:putPublication(alias_key, { path = linked_epub }),
    "publication validation followed an internal file link below an aliased root")
local unsafe_attempt_key = Crypto.sha256_hex("internal-attempt-alias")
local unsafe_attempt_parent = alias_store.root .. "/attempts/" .. unsafe_attempt_key
assert(successful("ln -s -- " .. quote(tmp) .. " " .. quote(unsafe_attempt_parent)))
expect(not alias_store:newWorkspace(unsafe_attempt_key), "workspace creation followed an internal directory link")
alias_store:close()
alias_store = assert(Store:new(alias_settings, alias_book))
expect(alias_store:getChapter(alias_key) and alias_store:getPublication(alias_key),
    "aliased storage stopped working after reopening")
alias_store:close()
local direct_target, direct_root = tmp .. "/direct-target", tmp .. "/direct-book-alias"
assert(lfs.mkdir(direct_target))
assert(successful("ln -s -- " .. quote(direct_target) .. " " .. quote(direct_root)))
local direct_store = assert(Store:new(settings, { book_id = "direct-book", cache_dir = direct_root }))
local direct_key = assert(direct_store:chapterKey({ chapterUid = 1 }, false))
local direct_workspace = assert(direct_store:newWorkspace(direct_key))
local direct_source = direct_workspace.path .. "/source.xhtml"
assert(direct_store:writeText(direct_source, "<p>direct alias</p>"))
assert(direct_store:putChapter(direct_key, { xhtml_path = direct_source, chapter_uid = "1" }))
expect(direct_store:getChapter(direct_key), "the configured book directory could not itself be a symbolic link")
direct_store:close()
expect(open_statements == 0 and connections == 0, "download store leaked SQLite resources")

assert(tmp:match("^/tmp/"), "test cleanup path must stay inside /tmp")
assert(successful("rm -rf -- " .. quote(tmp)))
helper.cleanup()
print(("download_store_spec: %d checks passed with real SQLite persistence"):format(checks))
