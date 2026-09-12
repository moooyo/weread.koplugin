-- Install the standalone real SQLite/filesystem adapters and verify them first.
dofile("spec/download_store_spec.lua")
local logger = require("weread.lib.logger")
logger.scoped = function() return logger end
local lfs = require("libs/libkoreader-lfs")
local root = os.tmpname(); os.remove(root); assert(lfs.mkdir(root))
local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
local function read(path)
    local file = assert(io.open(path, "rb")); local data = file:read("*a"); file:close(); return data
end
local function write(path, data)
    local file = assert(io.open(path, "wb")); assert(file:write(data)); assert(file:close())
end
package.preload["ffi/util"] = function()
    return { purgeDir = function(path)
        assert(path:sub(1, #root + 1) == root .. "/", "cleanup outside fixture")
        return os.execute("rm -rf -- " .. quote(path)) == 0
    end }
end
local archives = {}
package.preload["ffi/archiver"] = function()
    local Writer = {}
    function Writer:new() return setmetatable({ files = {} }, { __index = self }) end
    function Writer:open(path) self.path = path; return true end
    function Writer:setZipCompression(method) self.method = method; return true end
    function Writer:addFileFromMemory(name, data)
        self.files[name] = { data = data, compression = self.method }; return true
    end
    function Writer:addPath(name, path, recursive)
        assert(recursive)
        local listing = assert(io.popen("find " .. quote(path) .. " -type f"))
        for source in listing:lines() do
            self.files[name .. "/" .. source:sub(#path + 2)] = { data = read(source), compression = self.method }
        end
        listing:close(); return false
    end
    function Writer:close()
        archives[#archives + 1] = self.files
        require("spec.helpers.minimal_zip").write(self.path, self.files)
        return true
    end
    return { Writer = Writer }
end
local Content = require("weread.lib.content")
local calls, images = 0, 0
local chapters = {
    { chapterUid = 201, chapterIdx = 1, title = "Same", files = { "Text/chapter1.xhtml" } },
    { chapterUid = 202, chapterIdx = 2, title = "Same", files = { "Text/chapter2.xhtml" } },
}
Content.fetch_single_chapter_source = function(_client, _settings, _book, chapter, state)
    calls = calls + 1; state.css = "p { margin: 0; }"
    if chapter.chapterUid == 201 then
        return '<p>Source<a href="../Text/chapter2.xhtml#target-x"><span>[2]</span></a></p>'
            .. '<img src="https://images.test/shared.jpg?chapter=201"/>'
    end
    return '<section><p id="target-x">[2] Shared footnote text</p></section>'
        .. '<img src="https://images.test/shared.jpg?chapter=202"/>'
end
local client = {
    download_to_file = function(_self, url, path)
        images = images + 1
        write(path, "\255\216\255" .. url)
    end,
}
local popup = false
local settings = { cache_dir = root,
    get = function(_self, key, default)
        if key == "cache" then return { download_book_images = true, book_footnotes_in_popup = popup } end
        if key == "account" then return { user_vid = "fixture-account" } end
        return default
    end }
local context = { checkCancelled = function() end, cancelled = function() return false end,
    emit = function() end, sleep = function() end }
local Worker = require("weread.lib.book_download_worker")
local book = { book_id = "integration", title = "Integration book" }
local options = { suffix = "full" }
local first = Worker.run(settings, client, book, chapters, options, context)
assert(Content.validate_epub(first.path))
assert(first.footnote_stats.converted == 1 and first.footnote_stats.unresolved == 0)
local members = archives[#archives]
assert(members["OEBPS/text/chapter-001.xhtml"].data:find("Shared footnote text", 1, true))
assert(members["OEBPS/images/201-shared.jpg"] and members["OEBPS/images/202-shared.jpg"])
assert(calls == 2 and images == 2)
local replay = Worker.run(settings, client, book, chapters, options, context)
assert(replay.path == first.path and calls == 2 and #archives == 1,
    "real receipt was not reused after reopening SQLite")
popup = true
local second = Worker.run(settings, client, book, chapters, options, context)
assert(second.path ~= first.path and Content.validate_epub(first.path) and Content.validate_epub(second.path),
    "new edition overwrote or cleaned the previous edition")
assert(calls == 2 and images == 2, "render option change downloaded sources again")
popup = false
local original = Worker.run(settings, client, book, chapters, options, context)
assert(original.path == first.path and #archives == 2, "old render receipt returned a different edition")
local separate = Worker.run(settings, client, book, chapters,
    { suffix = "chapters", separate_chapters = true }, context)
assert(separate.chapter_paths["201"] ~= separate.chapter_paths["202"])
assert(Content.validate_epub(separate.chapter_paths["201"]) and Content.validate_epub(separate.chapter_paths["202"]))
local a, b = archives[#archives - 1], archives[#archives]
assert(a["OEBPS/images/201-shared.jpg"] and not a["OEBPS/images/202-shared.jpg"])
assert(b["OEBPS/images/202-shared.jpg"] and not b["OEBPS/images/201-shared.jpg"])
assert(calls == 2 and images == 2, "chapter mode did not reuse real source bundles")
assert(os.execute("rm -rf -- " .. quote(root)) == 0)
print("book_download_integration_spec: SQLite resume, editions, images and cross-chapter footnotes passed")
