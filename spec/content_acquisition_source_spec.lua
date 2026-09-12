package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
local Content = require("weread.lib.content")
local fixtures = require("spec.fixtures.content_decoder_cases")
local checks, persisted = 0, {}
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end
local original_cache = Content.cache_annotation_source
Content.cache_annotation_source = function(_settings, _book, _chapter, source, raw_text)
    persisted[#persisted + 1] = { source = source, raw_text = raw_text }
end
local chapter = { chapterUid = 1 }
local function fixture_client(format)
    local value = { format = format, requests = {} }
    function value:get_text()
        return '{"bookId":"fixture","psvts":"fixture-session"}'
    end
    function value:json_encode() return "{}" end
    function value:request(options)
        self.last_request_error = nil
        local name = options.url:match("([^/]+)$")
        self.requests[#self.requests + 1] = name
        if format == "txt" then
            if name == "e_0" then return '{"bookId":"fixture"}', 200 end
            return name == "t_0" and fixtures[2].single or "{}", 200
        end
        local responses = { e_0 = fixtures[6].e0, e_1 = fixtures[6].e1, e_3 = fixtures[6].e3 }
        return responses[name] or "{}", 200
    end
    return value
end
local settings = { get = function() return { download_book_images = false } end }
local txt_book = { book_id = "fixture", psvts = "fixture-session", _content_format = "txt" }
local txt_client = fixture_client("txt")
local xhtml, plain = Content.fetch_txt_as_xhtml(txt_client, settings, txt_book, chapter, { persist_source = false })
expect(plain == "a" and xhtml:find("<p>a</p>", 1, true), "TXT acquisition did not return its raw plain source")
expect(#persisted == 0, "direct TXT acquisition performed hidden source persistence")
local state = { source_options = { persist_source = false }, css = "cached css" }
xhtml = Content.fetch_single_chapter_source(txt_client, settings, txt_book, chapter, state)
expect(state.raw_source == "a" and xhtml:find("<p>a</p>", 1, true) and #persisted == 0,
    "known TXT source did not honor persistence-free acquisition")
local detected_book = { book_id = "fixture" }
xhtml = Content.fetch_single_chapter_source(fixture_client("txt"), settings, detected_book, chapter, state)
expect(detected_book._content_format == "txt" and state.raw_source == "a"
    and xhtml:find("<p>a</p>", 1, true) and #persisted == 0,
    "TXT format fallback dropped source options or plain text")
local epub_book = { book_id = "fixture" }
local epub_client = fixture_client("epub")
xhtml = Content.fetch_single_chapter_source(epub_client, settings, epub_book, chapter, state)
expect(state.raw_source == xhtml and xhtml:find("Offline content fixture.", 1, true),
    "EPUB acquisition did not retain pristine XHTML for the committing process")
expect(#persisted == 0, "EPUB acquisition performed hidden source persistence")
local original = state.raw_source
Content.finalize_single_chapter_content(epub_client, settings, epub_book, chapter, xhtml, state)
expect(state.raw_source == original, "content finalization replaced the original annotation source")
Content.fetch_single_chapter_source(epub_client, settings, epub_book, chapter, { css = "cached css" })
expect(#persisted == 1 and persisted[1].source == xhtml and persisted[1].raw_text == nil,
    "default EPUB source persistence changed")
Content.fetch_txt_as_xhtml(txt_client, settings, txt_book, chapter)
expect(#persisted == 2 and persisted[2].source == "a" and persisted[2].raw_text == true,
    "default raw TXT source persistence changed")
Content.cache_annotation_source = original_cache
print(("content_acquisition_source_spec: %d checks"):format(checks))
