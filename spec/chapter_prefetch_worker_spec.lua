package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end
local invocation, implementation
local engine_loads = 0
package.preload["weread.lib.book_download_worker"] = function()
    engine_loads = engine_loads + 1
    return { run = function(...)
        invocation = { ... }
        return implementation(...)
    end }
end
local Worker = require("weread.lib.chapter_prefetch_worker")
expect(engine_loads == 0, "prefetch loaded acquisition dependencies before its worker ran")
local settings, client, book = {}, {}, { book_id = "book" }
local chapter = { chapterUid = 2, title = "Two", chapterIdx = 1 }
local events, cancelled = {}, false
local cancellation = "__weread_worker_cancelled__"
local context = {
    token = "prefetch-run",
    cancelled = function() return cancelled end,
    checkCancelled = function() if cancelled then error(cancellation, 0) end end,
    emit = function(state) events[#events + 1] = state end,
    sleep = function() end,
}
local engine_state = { stage = "cached", index = 0, total = 7, bytes = 8192 }
local shared_result = {
    path = "/cache/book/.weread-jobs/run/chapter.epub",
    chapter_paths = { ["2"] = "/cache/book/.weread-jobs/run/chapter.epub" },
    chapter_sizes = { ["2"] = 512 }, size = 512,
    selected_uids = { "2" }, failed_uids = {}, cache_dir = "/cache/book",
    reader_url = "https://weread.qq.com/web/reader/book",
    publication_key = "publication-key",
    footnote_stats = { converted = 1 }, auth = { wr_ticket = "synthetic-renewal" },
}
implementation = function(_settings, _client, _book, _chapters, _options, shared_context)
    shared_context.emit(engine_state)
    shared_context.emit { stage = "source", attempt = 2, bytes = 4096 }
    shared_context.emit { stage = "epub", archive_stage = "validate", current = 4, count = 4 }
    return shared_result
end
local result = Worker.run(settings, client, book, chapter, context)
expect(engine_loads == 1, "prefetch did not load its shared acquisition engine")
expect(invocation[1] == settings and invocation[2] == client and invocation[3] == book,
    "prefetch replaced the shared engine's injected dependencies")
expect(#invocation[4] == 1 and invocation[4][1] == chapter,
    "prefetch did not provide exactly the requested chapter")
expect(invocation[5].single_chapter == true and invocation[5].suffix == "chapter"
    and invocation[5].separate_chapters == nil, "prefetch selected a different publication plan")
expect(invocation[6].checkCancelled == context.checkCancelled
    and invocation[6].cancelled == context.cancelled and invocation[6].sleep == context.sleep
    and invocation[6].token == context.token, "prefetch dropped shared worker control hooks")
expect(result == shared_result and result.chapter_uid == "2", "prefetch discarded shared publication metadata")
expect(result.path == result.chapter_paths["2"] and result.publication_key == "publication-key"
    and result.size == 512 and result.chapter_sizes["2"] == 512,
    "prefetch dropped fields required for parent publication and receipt updates")
expect(result.auth.wr_ticket == "synthetic-renewal" and result.footnote_stats.converted == 1,
    "prefetch did not preserve auth or footnote results")
expect(result.annotation_document.clean and #result.annotation_document.chapters == 1
    and result.annotation_document.chapters[1].chapterUid == 2
    and result.annotation_document.chapters[1].title == "Two"
    and result.annotation_document.chapters[1].chapterIdx == 1,
    "prefetch did not preserve its annotation descriptor contract")
expect(events[1].stage == "reader" and events[2].stage == "process"
    and events[2].bytes == 8192 and events[3].attempt == 2
    and events[4].archive_stage == "validate", "prefetch progress adaptation lost useful details")
for _, event in ipairs(events) do
    expect(event.index == 1 and event.total == 1, "prefetch emitted multi-chapter progress")
end
expect(engine_state.stage == "cached" and engine_state.index == 0 and engine_state.total == 7,
    "prefetch mutated the shared engine's progress object")

cancelled, invocation = true, nil
local ok, err = pcall(Worker.run, settings, client, book, chapter, context)
expect(not ok and err == cancellation and invocation == nil, "cancelled prefetch started acquisition")
cancelled = false
implementation = function() error(cancellation, 0) end
ok, err = pcall(Worker.run, settings, client, book, chapter, context)
expect(not ok and err == cancellation, "prefetch swallowed the shared engine's cancellation")
implementation = function() cancelled = true; return shared_result end
ok, err = pcall(Worker.run, settings, client, book, chapter, context)
expect(not ok and err == cancellation, "prefetch returned a result after cancellation")
cancelled = false
implementation = function() error("injected shared engine failure", 0) end
ok, err = pcall(Worker.run, settings, client, book, chapter, context)
expect(not ok and err == "injected shared engine failure", "prefetch hid the shared engine's error")
implementation = function() return { failed_uids = { "2" }, selected_uids = {} } end
expect(not pcall(Worker.run, settings, client, book, chapter, context),
    "failed chapter acquisition was reported as successful prefetch")
implementation = function() return { failed_uids = {}, selected_uids = { "2" } } end
expect(not pcall(Worker.run, settings, client, book, chapter, context),
    "prefetch accepted a completed chapter without an output path")
implementation = function()
    return { path = "/cache/book/chapter.epub", failed_uids = {}, selected_uids = { "99" } }
end
expect(not pcall(Worker.run, settings, client, book, chapter, context),
    "prefetch accepted a result for another chapter")
implementation = function()
    return { path = "/cache/book/chapter.epub", failed_uids = {}, selected_uids = { "3" } }
end
result = Worker.run(settings, client, book, { chapterId = 3, title = "Three" }, context)
expect(result.chapter_uid == "3" and result.annotation_document.chapters[1].chapterUid == 3,
    "prefetch dropped the chapterId compatibility alias")
print(("chapter_prefetch_worker_spec: %d checks"):format(checks))
