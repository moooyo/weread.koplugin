package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local function mkdir(path) assert(os.execute("mkdir -p " .. quote(path)) == 0) end
local function write(path, data)
    local file = assert(io.open(path, "wb"))
    assert(file:write(data))
    assert(file:close())
end
local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("*a")
    file:close()
    return data
end
local root = os.tmpname()
os.remove(root)
mkdir(root)
mkdir(root .. "/images")
mkdir(root .. "/incoming")
mkdir(root .. "/other")
mkdir(root .. "/bodies")

package.preload["logger"] = function()
    return { info = function() end, warn = function() end,
        err = function() end, dbg = function() end }
end
package.preload["weread.lib.crypto"] = function() return {} end
package.preload["weread.lib.reader_state"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { reader_url = function(book, chapter)
        return "https://example.test/" .. tostring(book) .. "/" .. tostring(chapter or "")
    end }
end
package.preload["ffi/util"] = function()
    return { purgeDir = function(path)
        expect(path:find(root .. "/.weread-download-", 1, true) == 1,
            "cleanup escaped the output scratch directory")
        return os.execute("rm -rf " .. quote(path)) == 0
    end }
end

local archives, close_failure, hidden_close_failure = {}, false, false
local body_reads, chapter_writes, peak_body_kb = 0, 0, 0
local measure_bodies, retain_bodies = false, true
local original_open = io.open
rawset(io, "open", function(path, mode)
    if measure_bodies and mode == "rb" and path:find(root .. "/bodies/", 1, true) == 1 then
        body_reads = body_reads + 1
        expect(body_reads == chapter_writes + 1, "chapter bodies were read ahead of archive writes")
    end
    return original_open(path, mode)
end)
package.preload["ffi/archiver"] = function()
    local Writer = {}
    function Writer:new() return setmetatable({ files = {}, directories = {} }, { __index = self }) end
    function Writer:open(path)
        self.path = path
        archives[#archives + 1] = self
        write(path, "archive-" .. tostring(#archives))
        return true
    end
    function Writer:setZipCompression(method) self.method = method; return true end
    function Writer:addFileFromMemory(name, data)
        local record = { bytes = #data, compression = self.method }
        local chapter = name:match("^OEBPS/text/chapter%-%d+%.xhtml$")
        if not chapter or retain_bodies then record.data = data end
        self.files[name] = record
        if measure_bodies and chapter then
            chapter_writes = chapter_writes + 1
            expect(body_reads == chapter_writes, "archive wrote a chapter before loading it")
            collectgarbage("collect")
            peak_body_kb = math.max(peak_body_kb, collectgarbage("count"))
        end
        return true
    end
    function Writer:addPath(name, path, recursive)
        expect(recursive == true, "file-backed assets used the unsupported single-file archive path")
        self.directories[#self.directories + 1] = path
        local files = assert(io.popen("find " .. quote(path) .. " -type f"))
        for source in files:lines() do
            local relative = source:sub(#path + 2)
            self.files[name .. "/" .. relative] = {
                data = read(source), compression = self.method,
            }
        end
        files:close()
        return false
    end
    function Writer:close()
        if close_failure then self.err = "injected archive close failure"; return false end
        require("spec.helpers.minimal_zip").write(self.path, self.files, { omit_end = hidden_close_failure })
        return true
    end
    return { Writer = Writer }
end

local Content = require("weread.lib.content")
local settings = { cache_dir = root, get = function(_self, _key, default) return default end }
local book = { book_id = "book", title = "Output Book", cache_dir = root }
local first = { chapterUid = 101, title = "Same title" }
local second = { chapterUid = 202, title = "Same title" }
local image_a, image_b = "\255\216\255image-A", "\255\216\255image-B"
write(root .. "/images/a.jpg", image_a)
write(root .. "/images/unrelated.jpg", image_b)
write(root .. "/other/b.jpg", image_b)
local asset_a = { href = "images/a.jpg", path = root .. "/images/a.jpg",
    media_type = "image/jpeg", store = true }
local asset_b = { href = "images/b.jpg", path = root .. "/other/b.jpg",
    media_type = "image/jpeg", store = true }
local path_a = Content.save_chapter_epub(settings, book, first, "<p>A</p>", { asset_a }, "body{}")
local archive_a = archives[#archives]
local path_b = Content.save_chapter_epub(settings, book, second, "<p>B</p>", { asset_b }, "body{}")
local archive_b = archives[#archives]
expect(path_a ~= path_b and #read(path_a) > 0 and #read(path_b) > 0, "same-title chapter outputs overwrote each other")
expect(book.annotation_documents[path_a].chapters[1].chapterUid == 101
    and book.annotation_documents[path_b].chapters[1].chapterUid == 202,
    "same-title chapter descriptors overwrote each other")
expect(archive_a.files["OEBPS/images/a.jpg"].data == image_a
    and archive_a.files["OEBPS/images/unrelated.jpg"] == nil
    and archive_a.files["OEBPS/images/b.jpg"] == nil,
    "chapter output included unrelated source-directory images")
expect(archive_b.files["OEBPS/images/b.jpg"].data == image_b
    and archive_b.files["OEBPS/images/a.jpg"] == nil, "second chapter resources were not isolated")
expect(archive_a.files["OEBPS/images/a.jpg"].compression == "store"
    and archive_a.files["OEBPS/text/chapter.xhtml"].compression == "deflate"
    and archive_a.files.mimetype.compression == "store", "EPUB compression policy was not preserved")
for _, directory in ipairs(archive_a.directories) do
    expect(io.open(directory .. "/a.jpg", "rb") == nil, "archive scratch resources were not cleaned")
end
expect(read(asset_a.path) == image_a, "archive cleanup removed the reusable source image")

local downloads = 0
local client = {}
function client:download_to_file(_url, path) downloads = downloads + 1; write(path, image_a); return path end
function client:get_binary() downloads = downloads + 1; return image_a end
local workspace = { incoming_dir = root .. "/incoming", asset_dir = root .. "/images" }
local source = '<p><img src="https://example.test/shared.jpg"/><img src="https://example.test/shared.jpg"/></p>'
local names = {}
local body_a, shared_a, complete_a = Content.download_remote_images_to_files(client, source, names, workspace)
local body_b, shared_b, complete_b = Content.download_remote_images_to_files(client, source, names, workspace)
expect(downloads == 1 and #shared_a == 1 and #shared_b == 1,
    "shared URL deduplication dropped a referencing chapter descriptor or duplicated same-chapter assets")
expect(complete_a and complete_b, "complete shared image downloads were marked incomplete")
expect(body_a == body_b and shared_a[1].path == shared_b[1].path, "shared image reference changed between chapters")
Content.save_chapter_epub(settings, book, { chapterUid = 303, title = "Shared" }, body_b, shared_b, "")
expect(archives[#archives].files["OEBPS/" .. shared_b[1].href] ~= nil,
    "the later chapter did not contain its shared image")
names = {}
local _, memory_a = Content.download_remote_images(client, source, names)
local _, memory_b = Content.download_remote_images(client, source, names)
expect(downloads == 2 and #memory_a == 1 and #memory_b == 1
    and memory_b[1].data == image_a, "memory asset mode dropped a reused descriptor")

local remote_pair = '<p><img src="https://example.test/first.jpg"/><img src="https://example.test/second.jpg"/></p>'
local non_image_client = { download_to_file = function(_self, _url, path)
    write(path, "<html>not an image</html>")
    return path
end }
local invalid_body, invalid_assets, invalid_complete = Content.download_remote_images_to_files(
    non_image_client, remote_pair, {}, workspace)
expect(invalid_body == remote_pair and #invalid_assets == 0 and invalid_complete == false,
    "HTTP-success non-image responses were reported as complete resources")
local state = { workspace = workspace }
Content.finalize_single_chapter_content({ download_to_file = non_image_client.download_to_file }, {
    get = function() return { download_book_images = true } end,
}, book, { chapterUid = 404 }, remote_pair, state)
expect(state.resources_complete == false, "finalization dropped explicit resource incompleteness")
local original_rename = os.rename
rawset(os, "rename", function(from, to)
    if from:find(workspace.incoming_dir .. "/remote-", 1, true) == 1 then
        return nil, "injected image rename failure"
    end
    return original_rename(from, to)
end)
local renamed_ok, _, renamed_assets, renamed_complete = pcall(
    Content.download_remote_images_to_files, client, remote_pair, {}, workspace)
rawset(os, "rename", original_rename)
expect(renamed_ok and #renamed_assets == 0 and renamed_complete == false,
    "local image commit failure was reported as complete resources")
local missing_requests = 0
local missing_client = { download_to_file = function(self)
    missing_requests = missing_requests + 1
    self.last_request_error = { kind = "http_error", status = 404, retryable = false }
    error("injected missing image", 0)
end }
local missing_body, _, missing_complete = Content.download_remote_images_to_files(
    missing_client, remote_pair, {}, workspace)
expect(missing_requests == 2 and missing_body == remote_pair and missing_complete == false,
    "ordinary missing images did not retain best-effort text and incomplete state")
for _, diagnostic in ipairs({ { status = 401 }, { status = 403 }, { status = 429 },
    { kind = "authentication" }, { kind = "session" }, { kind = "cancelled" } }) do
    local requests = 0
    local fatal_client = { download_to_file = function(self)
        requests = requests + 1
        self.last_request_error = diagnostic
        error("injected fatal image request", 0)
    end }
    local succeeded = pcall(Content.download_remote_images_to_files,
        fatal_client, remote_pair, {}, workspace)
    expect(not succeeded and requests == 1,
        "fatal image request continued through remaining chapter resources")
end

local output = Content.save_book_epub(settings, book, { first, second },
    { ["101"] = "<p>A</p>", ["202"] = "<p>B</p>" }, "full",
    { asset_a, asset_b, asset_a }, "body{}")
local combined = archives[#archives]
expect(combined.files["OEBPS/images/a.jpg"].data == image_a
    and combined.files["OEBPS/images/b.jpg"].data == image_b,
    "full-book resources could not come from private chapter directories")
local _, occurrences = combined.files["OEBPS/content.opf"].data:gsub('href="images/a.jpg"', "")
expect(occurrences == 1, "shared image appeared more than once in the manifest")
local conflict = { href = asset_a.href, path = asset_b.path, media_type = "image/jpeg" }
local ok, err = pcall(Content.save_book_epub, settings, book, { first }, { ["101"] = "<p>A</p>" },
    "full", { asset_a, conflict }, "")
expect(not ok and tostring(err):find("conflicting EPUB image href", 1, true),
    "conflicting private resources were silently overwritten")
local compressed_b = { href = asset_b.href, path = asset_b.path, media_type = "image/jpeg", store = false }
Content.save_book_epub(settings, book, { first }, { ["101"] = "<p>A</p>" }, "compression",
    { asset_a, compressed_b }, "")
expect(archives[#archives].files["OEBPS/images/a.jpg"].compression == "store"
    and archives[#archives].files["OEBPS/images/b.jpg"].compression == "deflate",
    "mixed resource compression groups did not honor explicit store flags")
local cover_asset = { href = "images/cover.jpg", data = image_b, media_type = "image/jpeg" }
Content.save_book_epub(settings, book, { first }, { ["101"] = "<p>A</p>" }, "cover",
    { cover_asset }, "", image_a)
expect(archives[#archives].files["OEBPS/images/cover.jpg"].data == image_b
    and archives[#archives].files["OEBPS/images/cover-2.jpg"].data == image_a,
    "generated book cover overwrote a chapter image")
ok = pcall(Content.save_chapter_epub, settings, book, first, "<p>A</p>", {
    { href = "images/../outside.jpg", path = asset_a.path, media_type = "image/jpeg" },
}, "")
expect(not ok, "invalid staged image traversal was accepted")

local chapters, bodies = {}, {}
for index = 1, 16 do
    local uid = tostring(index)
    local path = root .. "/bodies/" .. uid .. ".xhtml"
    write(path, "<html><body><p>" .. string.rep("x", 512 * 1024) .. "</p></body></html>")
    chapters[index] = { chapterUid = uid, title = "Chapter " .. uid }
    bodies[uid] = { path = path }
end
collectgarbage("collect")
local baseline_kb = collectgarbage("count")
measure_bodies, retain_bodies = true, false
Content.save_book_epub(settings, book, chapters, bodies, "staged", {}, "")
measure_bodies = false
expect(body_reads == #chapters and chapter_writes == #chapters, "staged chapter bodies were not read exactly once")
expect(peak_body_kb - baseline_kb < 4096, "full-book assembly retained all staged XHTML bodies")
print(string.format("content_output_spec: staged_body_peak_delta_kb=%.1f", peak_body_kb - baseline_kb))
write(root .. "/bodies/multiple.xhtml", "<html><body><p>First</p></body></html><html><body><p>Second</p></body></html>")
Content.save_chapter_epub(settings, book, { chapterUid = 404, title = "Staged chapter" },
    { path = root .. "/bodies/multiple.xhtml" }, {}, "")
local staged = archives[#archives].files["OEBPS/text/chapter.xhtml"].data
expect(staged:find("First", 1, true) and staged:find("Second", 1, true),
    "staged source lost a concatenated XHTML body")

write(output, "previous-valid-epub")
close_failure = true
ok = pcall(Content.save_book_epub, settings, book, { first }, { ["101"] = "<p>A</p>" }, "full", { asset_a }, "")
expect(not ok and read(output) == "previous-valid-epub", "archive close failure replaced a valid EPUB")
expect(io.open(output .. ".part", "rb") == nil, "archive close failure left a partial output")
close_failure = false
hidden_close_failure = true
ok = pcall(Content.save_book_epub, settings, book, { first }, { ["101"] = "<p>A</p>" }, "full", { asset_a }, "")
expect(not ok and read(output) == "previous-valid-epub", "an unreported archive close failure published a truncated EPUB")
hidden_close_failure = false
local zip64_path = root .. "/zip64.epub"
require("spec.helpers.minimal_zip").write(zip64_path, {
    mimetype = true, ["META-INF/container.xml"] = true, ["OEBPS/content.opf"] = true,
}, { zip64 = true })
expect(Content.validate_epub(zip64_path), "valid ZIP64 directory was rejected")
local incomplete_path = root .. "/incomplete.epub"
require("spec.helpers.minimal_zip").write(incomplete_path, { mimetype = true })
expect(not Content.validate_epub(incomplete_path), "a complete ZIP missing EPUB members was accepted")
local calls = 0
ok = pcall(Content.save_book_epub, settings, book, { first }, { ["101"] = "<p>A</p>" }, "full", { asset_a }, "", nil,
    { check_cancelled = function() calls = calls + 1; if calls >= 2 then error("cancelled") end end })
expect(not ok and read(output) == "previous-valid-epub", "cancellation published an incomplete output")
local previous_lfs = package.loaded["libs/libkoreader-lfs"]
local links = 0
package.loaded["libs/libkoreader-lfs"] = { link = function(source_path, destination)
    links = links + 1
    write(destination, read(source_path))
    return true
end }
ok = pcall(Content.save_book_epub, settings, book, { first }, { ["101"] = "<p>A</p>" }, "full", { asset_a, asset_b }, "", nil,
    { check_cancelled = function() if links > 0 then error("cancelled after linking one asset") end end })
package.loaded["libs/libkoreader-lfs"] = previous_lfs
expect(not ok and links == 1 and read(output) == "previous-valid-epub",
    "hard-link resource staging did not check cancellation between assets")

rawset(io, "open", original_open)
assert(os.execute("rm -rf " .. quote(root)) == 0)
print(("content_output_spec: %d checks"):format(checks))
