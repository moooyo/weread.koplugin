-- Prefetch uses the same durable acquisition and publication pipeline as a
-- manual chapter download. The parent owns publication and cache registration.
local M = {}

function M.run(settings, client, book, chapter, context)
    local uid = tostring(chapter.chapterUid or chapter.chapterId or "")
    assert(uid ~= "", "Missing chapter UID")
    context.checkCancelled()
    local shared_context = {}
    for key, value in pairs(context) do shared_context[key] = value end
    shared_context.emit = function(state)
        local progress = {}
        for key, value in pairs(state or {}) do progress[key] = value end
        progress.index, progress.total = 1, 1
        if progress.stage == "cached" then progress.stage = "process" end
        context.emit(progress)
    end
    shared_context.emit { stage = "reader" }
    local BookWorker = require("weread.lib.book_download_worker")
    local result = BookWorker.run(settings, client, book, { chapter }, {
        single_chapter = true, suffix = "chapter",
    }, shared_context)
    context.checkCancelled()
    assert(type(result) == "table" and #(result.failed_uids or {}) == 0
        and type(result.selected_uids) == "table" and #result.selected_uids == 1
        and tostring(result.selected_uids[1]) == uid,
        "Chapter prefetch did not complete: " .. uid)
    local path = result.chapter_paths and result.chapter_paths[uid] or result.path
    assert(type(path) == "string" and path ~= "", "Chapter prefetch returned no EPUB: " .. uid)
    result.path = path
    result.chapter_uid = uid
    result.annotation_document = {
        clean = true,
        chapters = { {
            chapterUid = chapter.chapterUid or chapter.chapterId,
            title = chapter.title,
            chapterIdx = chapter.chapterIdx,
        } },
    }
    return result
end

return M
