-- UI-owned scheduling for direct acquisition, commit, and assembly children.
-- Bodies stay on disk; only a bounded window of ready manifests reaches the UI.
local Policy = require("weread.lib.download_policy")
local WorkerSettings = require("weread.lib.worker_settings")

local M = {}

local function scalar_copy(source)
    local result = {}
    for key, value in pairs(source or {}) do
        if type(value) ~= "table" then result[key] = value end
    end
    return result
end

local function chapter_copy(chapter)
    local result = scalar_copy(chapter)
    if type(chapter.files) == "table" then
        result.files = {}
        for index, value in ipairs(chapter.files) do result.files[index] = value end
    end
    return result
end

local function chapter_uid(chapter)
    return tostring(chapter.chapterUid or chapter.chapterId or chapter.chapter_uid or "")
end

function M.start(group, settings, client, input_book, input_chapters, options)
    options = options or {}
    local worker = options.worker or require("weread.lib.book_download_worker")
    local factory = WorkerSettings.job_factory(settings, client)
    local book, chapters = scalar_copy(input_book), {}
    book.psvts, book.pclts, book.token = nil, nil, nil
    if not book.cache_dir or book.cache_dir == "" then
        book.cache_dir = require("weread.lib.content").book_resolved_dir(
            settings, book.book_id or book.bookId, input_book)
    end
    for index, chapter in ipairs(input_chapters) do chapters[index] = chapter_copy(chapter) end
    local render_options = { suffix = options.suffix, single_chapter = options.single_chapter,
        separate_chapters = options.separate_chapters }
    local limit = Policy.concurrency(options.concurrency)
    local state = { completed = 0, acquired = 0, waiting = 0, ready = {}, ready_head = 1,
        ready_count = 0, pending = {}, pending_head = 1, failed = {}, jobs = {}, ended = false }
    local pump, acquire, commit, assemble
    local pumping, pump_again = false, false

    local function stopped()
        return state.ended or group:cancelled()
    end

    local function emit(stage, job, detail)
        if stopped() then return end
        local progress = scalar_copy(detail)
        progress.task_token, progress.updated_at = nil, nil
        progress.stage = stage or progress.stage or "source"
        progress.index = job and job.ordinal or math.min(#chapters, state.completed + 1)
        progress.total, progress.completed = #chapters, state.completed
        progress.active, progress.concurrency = state.acquired, limit
        if job then progress.chapter_uid = job.chapter_uid end
        group:emit(progress)
    end

    local function fail(failure)
        if stopped() then return end
        state.ended = true
        local details = type(failure) == "table" and failure or {}
        group:finish({ ok = false,
            error = type(failure) == "table" and tostring(failure.error or "Download failed")
                or tostring(failure or "Download failed"),
            pause = details.pause == true,
            http_status = details.http_status,
            error_kind = details.error_kind,
            api_code = details.api_code,
        })
    end

    local function submit(kind, task, callback, job)
        local delivered = false
        local function done(result)
            if delivered then return end
            delivered = true
            if stopped() then return end
            callback(result or { ok = false, error = "worker_no_result" })
        end
        local handle, err = group:submit {
            kind = kind,
            chapter_uid = job and job.chapter_uid,
            task = function(context)
                local private_settings, private_client = factory()
                return task(private_settings, private_client, context)
            end,
            on_done = done,
            on_progress = function(progress) emit(progress.stage, job, progress) end,
            timeout = 360,
        }
        if not handle and not delivered then done({ ok = false, error = err or "worker_unavailable" }) end
    end

    local function enqueue(job)
        job.status = "pending"
        state.pending[#state.pending + 1] = job
    end

    local function pop_pending()
        local job = state.pending[state.pending_head]
        if job then
            state.pending[state.pending_head] = false
            state.pending_head = state.pending_head + 1
        end
        return job
    end

    local function failed_acquisition(job, failure)
        local decision = Policy.classify(failure, job.attempts)
        if decision.pause then fail(decision); return end
        if decision.retry then
            job.status = "waiting"
            state.waiting = state.waiting + 1
            emit("retry", job, { attempt = job.attempts + 1, attempts = Policy.MAX_ATTEMPTS,
                delay = decision.delay })
            local handle, err = group:defer(decision.delay, function()
                if stopped() then return end
                state.waiting = state.waiting - 1
                enqueue(job)
                pump()
            end)
            if not handle then fail(err or "Could not schedule download retry"); return end
        else
            job.status = "failed"
            state.completed = state.completed + 1
            state.failed[#state.failed + 1] = job.chapter_uid
            emit("failed", job, { error = decision.error })
        end
        pump()
    end

    acquire = function(job)
        job.status, job.attempts = "acquiring", (job.attempts or 0) + 1
        state.acquired = state.acquired + 1
        local acquisition_options = { key = job.key, ordinal = job.ordinal, total = #chapters,
            attempt = job.attempts, css_path = state.css_path, content_format = state.content_format }
        emit("source", job, { attempt = job.attempts })
        submit("acquire", function(private_settings, private_client, context)
            return worker.acquire(private_settings, private_client, book, chapters[job.ordinal],
                acquisition_options, context)
        end, function(result)
            state.acquired = state.acquired - 1
            local ready = result.ok and result.value
            if type(ready) ~= "table" or ready.status ~= "ready" then
                failed_acquisition(job, type(ready) == "table" and ready or result)
                return
            end
            if ready.key ~= job.key or ready.chapter_uid ~= job.chapter_uid then
                fail("Chapter acquisition identity changed"); return
            end
            job.status, job.ready = "ready", ready
            state.ready[#state.ready + 1] = job
            state.ready_count = state.ready_count + 1
            pump()
        end, job)
    end

    commit = function(job)
        state.committing, job.status = job, "committing"
        local ready = job.ready
        submit("commit", function(private_settings, _private_client, context)
            return worker.commit(private_settings, book, chapters[job.ordinal], ready, context)
        end, function(result)
            state.committing = nil
            local value = result.ok and result.value
            if type(value) ~= "table" then fail(result); return end
            if value.key ~= job.key or value.chapter_uid ~= job.chapter_uid then
                fail("Chapter commit identity changed"); return
            end
            job.ready, job.status = nil, "done"
            state.css_path = state.css_path or value.css_path
            state.content_format = state.content_format or value.content_format
            state.primed = true
            state.completed = state.completed + 1
            emit("cached", job)
            pump()
        end, job)
    end

    assemble = function()
        state.assembling = true
        local assembly_options = scalar_copy(render_options)
        assembly_options.failed_uids = state.failed
        emit("epub")
        submit("assemble", function(private_settings, private_client, context)
            return worker.assemble(private_settings, private_client, book, chapters, assembly_options, context)
        end, function(result)
            if not result.ok or type(result.value) ~= "table" then fail(result); return end
            state.ended = true
            group:finish(result)
        end)
    end

    pump = function()
        if stopped() or state.assembling then return end
        if pumping then pump_again = true; return end
        pumping = true
        repeat
            pump_again = false
            if not state.committing and state.ready_count > 0 then
                local job = state.ready[state.ready_head]
                state.ready[state.ready_head] = false
                state.ready_head = state.ready_head + 1
                state.ready_count = state.ready_count - 1
                commit(job)
            end
            while not stopped() and state.pending[state.pending_head] do
                local window = state.acquired + state.ready_count + (state.committing and 1 or 0)
                -- Prime shared CSS/format once; subsequent acquisitions form a
                -- sliding window. Backoff releases the request slot.
                if window >= (state.primed and limit or 1) then break end
                acquire(pop_pending())
            end
            if not stopped() and not state.assembling and state.completed == #chapters
                and state.acquired == 0 and state.ready_count == 0
                and not state.committing and state.waiting == 0 then assemble() end
        until not pump_again or stopped()
        pumping = false
    end

    submit("prepare", function(private_settings, _private_client, context)
        return worker.prepare(private_settings, book, chapters, render_options, context)
    end, function(result)
        local plan = result.ok and result.value
        if type(plan) ~= "table" or type(plan.jobs) ~= "table" or #plan.jobs ~= #chapters then
            fail(result.error or "Invalid download plan"); return
        end
        if plan.published then
            state.ended = true
            group:finish({ ok = true, value = plan.published })
            return
        end
        book = plan.book or book
        state.css_path, state.content_format = plan.css_path, plan.content_format
        state.primed = plan.css_path ~= nil
        for ordinal, job in ipairs(plan.jobs) do
            if job.ordinal ~= ordinal or job.chapter_uid ~= chapter_uid(chapters[ordinal])
                or type(job.key) ~= "string" then fail("Download plan identity changed"); return end
            state.jobs[ordinal] = job
            if job.cached then
                job.status = "done"
                state.completed = state.completed + 1
            else enqueue(job) end
        end
        emit("prepared")
        pump()
    end)
    return state
end

return M
