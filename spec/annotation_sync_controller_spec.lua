package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local scheduled, shown, notices, progress_titles, progress_updates, prevented, allowed = {}, {}, {}, {}, {}, 0, 0
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) scheduled[#scheduled + 1] = callback end,
        close = function() end, setDirty = function() end, show = function(_self, widget) shown[#shown + 1] = widget end,
    }
end
package.preload["weread.lib.standby_guard"] = function()
    return { acquire = function() prevented = prevented + 1; return {} end,
        release = function() allowed = allowed + 1 end }
end
package.preload["ui/widget/confirmbox"] = function() return { new = function(_self, args) return args end } end
package.preload["weread.ui.download_dialog"] = function()
    return { new = function(_self, args)
        args.show = function() end; args.close = function() end
        args.setTitle = function(dialog, title)
            dialog.current_title = title
            progress_titles[#progress_titles + 1] = title
            progress_updates[#progress_updates + 1] = {
                title = title,
                progress = dialog.current_progress,
            }
        end
        args.reportProgress = function(dialog, progress)
            dialog.current_progress = progress
        end
        return args
    end }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(s) return s end, T = function(s, ...) local v = {...}
        return (s:gsub("%%(%d+)", function(i) return tostring(v[tonumber(i)]) end)) end }
end
local Controller = require("weread.ui.annotation_sync_controller")
local cache, calls, applied = { show_annotations = true }, 0, 0
local host = {
    _reader_session_gen = 1,
    ui = { document = { file = "single", getXPointer = function() return "0" end,
        findAllText = function() return { { start = "0", ["end"] = "1" } } end,
        compareXPointers = function(_self, a, b) return a == b and 0 or a < b and 1 or -1 end } },
    client = { get_chapter_underlines = function() calls = calls + 1
        return true, { underlines = { { range = "0-1", markText = "a" } } } end,
        build_chapter_review_batches = function(_self, ranges)
            return { { { range = ranges[1] } } }
        end,
        get_chapter_reviews_batch = function()
            return true, { reviews = {} }
        end },
    settings = { get = function() return cache end, set = function() end, flush = function() end },
    _xpointer_overlay = { setRecords = function(self, records) self.records = records end,
        setEnabled = function() end },
    showInfo = function(_self, message) notices[#notices + 1] = message end,
    showTransientInfo = function() end,
    applyAnnotationVisibility = function() applied = applied + 1 end,
    requireLogin = function() return true end,
    isNetworkConnected = function() return true end,
    runOnlineTask = function(_self, _label, callback) callback() end,
    _xpointerOverlayPrototypeAvailable = function() return true end,
}
local worker_launches = {}
host.prefetch_worker = {
    available = function() return true end,
    start = function(_self, options)
        worker_launches[#worker_launches + 1] = options
        local handle = {}
        if options.on_launch then options.on_launch(123, 96 * 1024) end
        local emitted = {}
        local ok, value = pcall(options.task, {
            checkCancelled = function() end,
            emit = function(state)
                emitted[#emitted + 1] = state
                if options.on_progress then options.on_progress(state) end
            end,
            sleep = function() end,
        })
        options.on_done(ok and { ok = true, value = value }
            or { ok = false, error = value })
        return true, handle
    end,
    cancel = function() return true end,
}
for k,v in pairs(Controller) do host[k] = v end
local store = helper.new()
host.annotation_store = store
host.external_annotations_db = store.legacy
local context = { path = "single", book_id = "book", document_key = "single", store = store,
    binding = { book_id = "book", title = "fixture" }, statuses = {},
    chapters = { { chapterUid = "1" } }, ranges = {} }
host._annotation_context = context
host._annotationBinding = function() return context.binding end
host._prepareAnnotationContext = function() return context end
host._usesUnifiedAnnotations = function() return true end
local function drain()
    for _ = 1, 1000 do
        if #scheduled == 0 then return end
        table.remove(scheduled, 1)()
    end
    error("scheduler did not settle")
end
assert(not host:_annotationsVisibleForCurrentDocument(),
    "an unmatched clean document must not appear to have visible annotations")
assert(host:ensureAnnotationDisplay() and #shown == 1 and calls == 0,
    "unmatched display must ask before starting network work")
shown[1].ok_callback()
drain()
assert(calls == 1 and #host._xpointer_overlay.records == 1)
assert(store:get("book", "meta", "enabled") == true)
assert(not host:isAnnotationPrefetchEnabled(),
    "annotation prefetch must default to off")
assert(host:setAnnotationPrefetchEnabled(true)
        and cache.prefetch_annotations == true
        and host:isAnnotationPrefetchEnabled(),
    "annotation prefetch preference was not enabled globally")
assert(prevented == allowed and prevented == 1, "standby guard leaked after completion")
assert(applied == 1 and store:get("book", "display", "single"))
assert(host:_annotationsVisibleForCurrentDocument(),
    "a matched document with the display preference enabled must appear visible")
cache.show_annotations = false
assert(not host:_annotationsVisibleForCurrentDocument(),
    "the document must appear hidden when the display preference is disabled")
cache.show_annotations = true
local titles = table.concat(progress_titles, "\n")
assert(titles:find("Downloading thoughts 1/1 · chapter 1/1", 1, true),
    "thought download progress did not expose item counts")
assert(titles:find("Matching underlines 1/1 · chapter 1/1", 1, true),
    "matching progress did not expose item counts")
local thought_progress_moved = false
for _, update in ipairs(progress_updates) do
    if update.title == "Downloading thoughts 1/1 · chapter 1/1"
        and update.progress == 0.4 then
        thought_progress_moved = true
        break
    end
end
assert(thought_progress_moved,
    "thought item progress did not advance the chapter progress bar")
-- Cancel before a queued request and ensure stale callbacks cannot run.
host:_runAnnotationJob(context, { refresh = true })
host:_cancelUnifiedAnnotationSync()
drain()
assert(calls == 1 and prevented == allowed)
-- A new reader session must invalidate callbacks even when path is unchanged.
host:_runAnnotationJob(context, { refresh = true })
host._reader_session_gen = 2
drain()
assert(calls == 1 and prevented == allowed)
-- Prefetch shares source data and never touches the open document.
host:prefetchChapterAnnotations({ book_id = "book" }, { chapterUid = "2" })
drain()
assert(calls == 2 and store:get("book", "source", "2"))
assert(worker_launches[1].preserve_queue == true
    and worker_launches[#worker_launches].preserve_queue == false,
    "foreground annotations must be protected while speculative prefetch remains replaceable")
assert(not store:get("book", "projection", "single:2"))
-- Turning off preparation suppresses future annotation requests.
host:setAnnotationPrefetchEnabled(false)
host:prefetchChapterAnnotations({ book_id = "book" }, { chapterUid = "3" })
drain()
assert(calls == 2)
-- Multi-select keeps source catalog order, including noncontiguous choices.
context.chapters = { { chapterUid = "1" }, { chapterUid = "2" }, { chapterUid = "3" } }
local picker, chosen, picker_options
host.showList = function(_self, _title, items, _empty, options)
    picker, picker_options = items, options
    return { updateItems = function() end }
end
host.startUnifiedAnnotationSync = function(_self, options) chosen = options.chapters end
host:chooseAnnotationChapters()
picker[4].callback(); picker[2].callback(); picker[1].callback()
assert(#chosen == 2 and chosen[1].chapterUid == "1" and chosen[2].chapterUid == "3")
-- The picker opens on the page containing the current local XPointer range.
-- This deliberately uses uneven local chapter positions and unrelated remote
-- UIDs so remote/local chapter-number offsets cannot affect the result.
context.chapters, context.ranges = {}, {}
local starts = { 0, 8, 19, 33, 48, 65, 79, 91, 103, 1000, 1300, 1600, 1900, 2200, 2500 }
for index, start in ipairs(starts) do
    local uid = tostring(100 + index)
    context.chapters[index] = { chapterUid = uid }
    context.ranges[uid] = { start_xpointer = tostring(start) }
end
host.ui.document.getXPointer = function() return "1120" end
host.ui.document.compareXPointers = function(_self, a, b)
    a, b = tonumber(a), tonumber(b)
    return a == b and 0 or a < b and 1 or -1
end
host:chooseAnnotationChapters()
assert(picker_options.initial_page == 2,
    "chapter picker did not open on the current local chapter page")
-- Matching one selected chapter must activate its projection immediately;
-- waiting for every mapped chapter leaves valid underlines invisible.
context.chapters = { { chapterUid = "1" }, { chapterUid = "2" } }
context.ranges = {}
context.statuses = {}
host._unified_annotations_active = false
store:put("book", "display", "single", nil)
local applied_before_partial = applied
host:_runAnnotationJob(context, { chapters = { context.chapters[1] }, refresh = true })
drain()
assert(store:get("book", "display", "single") == true
    and host._unified_annotations_active == true
    and applied == applied_before_partial + 1,
    "a successfully matched selected chapter did not activate its projection")
store:put("book", "display", "single", nil)
host:onUnifiedAnnotationsReady()
assert(store:get("book", "display", "single") == true,
    "an existing partial projection was not activated when reopening the book")
-- Clearing is the explicit refresh path: shared annotations and every file's
-- coordinates are removed book-wide, even for chapters absent from the current
-- local edition. Cached chapter text and the local-book binding remain reusable.
context.chapters = { { chapterUid = "1" }, { chapterUid = "2" }, { chapterUid = "3" } }
context.ranges = {}
store:put("book", "original", "1", { spans = {} }, "1")
store:put("book", "original", "99", { spans = {} }, "99")
store:put("book", "projection", "other:1", { records = {} }, "1")
store:put("book", "projection", "stale:99", { records = { {} } }, "99")
store:put("book", "thought", "99:range", { { content = "stale" } }, "99")
store:put("book", "source", "99", { underlines = { {} } }, "99")
store:put("book", "display", "old-document-key", true)
store:put("book", "manual_only", "old-document-key", true)
helper.legacy_entries.single = {
    binding = { book_id = "book", title = "fixture" },
    records = { { chapter_uid = "99", pos0 = "0", pos1 = "1" } },
}
host:clearUnifiedAnnotationProjections()
assert(not store:get("book", "source", "1")
    and not store:get("book", "projection", "single:1")
    and not store:get("book", "projection", "other:1")
    and not store:get("book", "source", "99")
    and not store:get("book", "thought", "99:range")
    and not store:get("book", "projection", "stale:99"),
    "clearing did not remove all book-wide annotations and coordinates")
assert(not store:get("book", "display", "old-document-key")
    and not store:get("book", "manual_only", "old-document-key")
    and store:get("book", "manual_only", "single") == true,
    "clearing retained a stale document display key")
assert(store:get("book", "original", "1") and store:get("book", "original", "99"),
    "clearing discarded reusable original chapter text")
assert(helper.legacy_entries.single
    and helper.legacy_entries.single.binding.book_id == "book"
    and helper.legacy_entries.single.records == nil,
    "clearing did not remove legacy records while preserving the binding")

-- Foreground requests prepare sources through the worker, then match only in
-- the document-owning process. No network work starts in the queued UI step.
local worker_options, worker_cancellations, document_matches = nil, 0, 0
local original_find = host.ui.document.findAllText
host.ui.document.findAllText = function(...)
    document_matches = document_matches + 1
    return original_find(...)
end
host.prefetch_worker.start = function(_self, options)
    worker_options = options
    return true, {}
end
host.prefetch_worker.cancel = function() worker_cancellations = worker_cancellations + 1; return true end
context.chapters = { { chapterUid = "worker-phase" } }
context.statuses = {}
local calls_before_worker = calls
host:_runAnnotationJob(context, {})
drain()
assert(worker_options and calls == calls_before_worker and document_matches == 0,
    "foreground source preparation executed network or document work before the worker ran")
assert(worker_options.preserve_queue == true and worker_options.book_id == context.book_id,
    "foreground annotation work did not reserve its queue entry or book identity")
worker_options.on_launch(456, 96 * 1024)
local worker_value = worker_options.task {
    checkCancelled = function() end,
    emit = function(state) worker_options.on_progress(state) end,
    sleep = function() end,
}
assert(calls == calls_before_worker + 1 and document_matches == 0
    and store:get("book", "source_status", "worker-phase"),
    "source worker must save annotations without touching the live document")
worker_options.on_done({ ok = true, value = worker_value })
drain()
assert(document_matches > 0 and calls == calls_before_worker + 1
    and store:get("book", "projection", "single:worker-phase"),
    "worker completion did not start offline document matching")
assert(prevented == allowed and host._external_annotation_sync == nil,
    "two-phase completion retained the guard or active request")

-- Clearing waits for an existing child to stop before deleting its database
-- rows, so an in-flight response cannot recreate the just-cleared cache.
host:_runAnnotationJob(context, { refresh = true })
drain()
host:clearUnifiedAnnotationProjections()
assert(worker_cancellations == 1 and store:get("book", "source_status", "worker-phase"),
    "clear deleted source data before the worker acknowledged cancellation")
local cleared_context = context
context = { path = "other-book", book_id = "other-book", document_key = "other-book",
    store = store, chapters = {}, statuses = {}, ranges = {}, binding = { book_id = "other-book" } }
host._annotation_context = context
host.ui.document.file = context.path
store:put("other-book", "source", "keep", { underlines = {} }, "keep")
local other_overlay = { { id = "other-book-overlay" } }
host._xpointer_overlay.records = other_overlay
worker_options.on_done({ ok = false, cancelled = true, error = "cancelled" })
assert(not store:get("book", "source_status", "worker-phase")
    and host._external_annotation_sync == nil and prevented == allowed,
    "clear did not finish after worker cancellation")
assert(store:get("other-book", "source", "keep") and host._xpointer_overlay.records == other_overlay,
    "deferred cleanup cleared the newly opened book instead of its captured context")
context = cleared_context
host._annotation_context = context
host.ui.document.file = context.path

-- Platforms without subprocess support retain the explicit foreground path.
local fallback_notices = {}
host.showTransientInfo = function(_self, message) fallback_notices[#fallback_notices + 1] = message end
host.prefetch_worker.available = function() return false end
context.chapters = { { chapterUid = "fallback" } }
host:_runAnnotationJob(context, {})
drain()
assert(#fallback_notices > 0 and store:get("book", "projection", "single:fallback"),
    "the unavailable-worker fallback did not explain and complete foreground matching")

-- A worker may fail to launch without delivering a completion callback.
host.prefetch_worker.available = function() return true end
host.prefetch_worker.start = function() return false, "low_memory" end
host:_runAnnotationJob(context, { refresh = true })
drain()
assert(host._external_annotation_sync == nil and prevented == allowed,
    "failed worker launch retained the guard or active request")
helper.cleanup()
print("annotation_sync_controller_spec: consent, completion, cancellation, sessions and prefetch passed")
