package.path = "./?.lua;./?/init.lua;" .. package.path

-- Exercise the real downloader and worker coordinator. The runner defers its
-- child callback explicitly, without spawning a process or using the network.
local checks, failures = 0, 0
local function expect(value, message)
    checks = checks + 1
    if not value then failures = failures + 1; print("FAIL " .. message) end
end
local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
local directories = {}
local function mkdir(path)
    local result = os.execute("mkdir -p -- " .. quote(path))
    assert(result == 0 or result == true)
    directories[path] = true
end
local function write(path, value)
    local file = assert(io.open(path, "wb")); assert(file:write(value)); assert(file:close())
end
local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close(); return true
end
local root = os.tmpname(); os.remove(root); mkdir(root)
local environment
local codec, sequence = {}, 0
package.preload["json"] = function() return {
    encode = function(value)
        sequence = sequence + 1; local key = "fixture-" .. sequence
        codec[key] = value; return key
    end,
    decode = function(value) return codec[value] end,
} end
local logger = { info = function() end, warn = function() end, err = function() end }
logger.scoped = function() return logger end
package.preload["weread.lib.logger"] = function() return logger end
package.preload["weread.lib.footnotes"] = function() return {} end
package.preload["weread.lib.i18n"] = function() return { tr = function(value) return value end } end
package.preload["ui/widget/confirmbox"] = function() return { new = function(_, value) return value end } end
package.preload["device"] = function() return {
    isKindle = function() return false end, isKobo = function() return false end,
    isCervantes = function() return false end,
} end
package.preload["pluginshare"] = function() return {} end
local manager = {
    scheduleIn = function(_, _, callback) environment.scheduled[#environment.scheduled + 1] = callback end,
    preventStandby = function() environment.prevented = environment.prevented + 1 end,
    allowStandby = function() environment.allowed = environment.allowed + 1 end,
    show = function() end,
}
package.preload["ui/uimanager"] = function() return manager end
package.preload["ui/time"] = function() return { now = function() return 1000 end } end
package.preload["ffi/util"] = function() return { template = function(value, ...)
    local arguments = { ... }
    return (value:gsub("%%(%d+)", function(index) return tostring(arguments[tonumber(index)] or "") end))
end } end
package.preload["libs/libkoreader-lfs"] = function() return {
    attributes = function(path, field)
        if directories[path] then return field and "directory" or { mode = "directory" } end
        if exists(path) then return field and "file" or { mode = "file" } end
    end,
    mkdir = function(path) mkdir(path); return true end,
} end
package.preload["weread.ui.download_dialog"] = function() return { new = function(_, options)
    local dialog = { options = options, closed = false, titles = {} }
    function dialog:show() self.shown = true end
    function dialog:close() self.closed = true end
    function dialog:setTitle(title) self.titles[#self.titles + 1] = title end
    function dialog:reportProgress(value) self.progress = value end
    environment.dialogs[#environment.dialogs + 1] = dialog
    return dialog
end } end
package.preload["weread.lib.book_download_worker"] = function() return { run = function(settings, client, book, chapters, options, context)
    environment.child_runs = environment.child_runs + 1
    environment.child_arguments = { settings = settings, client = client, book = book,
        chapters = chapters, options = options }
    context.checkCancelled()
    if environment.serial_pause then
        context.emit(environment.serial_pause)
        error(environment.serial_pause.error, 0)
    end
    context.emit { stage = "cached", index = 2 }
    return environment.result
end } end

local Content = require("weread.lib.content")
Content.ensure_reader_state = function() error("network acquisition ran on the UI path") end
Content.save_chapter_epub = function() error("chapter packaging ran on the UI path") end
Content.save_book_epub = function() error("book packaging ran on the UI path") end
local BackgroundWorker = require("weread.lib.background_worker")
local Downloader = require("weread.lib.downloader")
local environment_count = 0
local function create_environment(group_mode)
    environment_count = environment_count + 1
    local env = { scheduled = {}, callbacks = {}, done = {}, next_pid = 10, dialogs = {},
        completions = {}, infos = {}, prevented = 0, allowed = 0, child_runs = 0,
        writes = 0, flushes = 0, auth_writes = 0, start_notices = 0 }
    environment = env
    env.temp_dir = root .. "/worker-" .. environment_count
    mkdir(env.temp_dir)
    env.cache_dir = root .. "/book-" .. environment_count
    local edition = env.cache_dir .. "/.weread-jobs/account/attempts/edition/attempt-1-1-1"
    mkdir(edition)
    env.path = edition .. "/book.epub"
    write(env.path, "private EPUB fixture")
    env.values = { books = { book = { book_id = "book", progress = 88,
        cached_chapters = { unrelated = "/existing/chapter.epub" } } },
        cookies = { session = "parent-session" }, cache = {} }
    env.settings = {
        get = function(_, key, default) local value = env.values[key]; if value == nil then return default end; return value end,
        set = function(_, key, value) env.writes = env.writes + 1; env.values[key] = value end,
        flush = function()
            env.flushes = env.flushes + 1
            if env.fail_flush then error("injected metadata flush failure") end
        end,
        update_auth = function(_, credentials)
            env.auth_writes = env.auth_writes + 1; env.values.cookies = credentials.cookies
        end,
    }
    env.worker = BackgroundWorker:new { temp_dir = env.temp_dir, scheduler = manager,
        now = function() return 1000 end,
        read_memory = function() return "MemAvailable: 524288 kB\n" end,
        runner = {
            run = function(callback)
                env.next_pid = env.next_pid + 1; env.callbacks[env.next_pid] = callback
                return env.next_pid
            end,
            is_done = function(pid) return env.done[pid] == true end,
            terminate = function(pid) env.done[pid] = true end,
        } }
    -- Keep the established single-task compatibility cases independent from
    -- the group-specific cases below.
    if not group_mode then env.worker.startGroup = false end
    env.downloader = Downloader:new { settings = env.settings, client = {}, background_worker = env.worker,
        require_login = function() return true end,
        run_online_task = function(_, callback) callback(); return true end,
        refresh_ui = function() end,
        refresh_shelf = function() if env.fail_refresh then error("injected UI refresh failure") end end,
        show_info = function(value) env.infos[#env.infos + 1] = value end,
        show_transient = function() end, safe_callback = function(_, callback) return callback end,
        open_file = function(path) env.opened = path end,
    }
    env.book = { book_id = "book", title = "Book", progress = 10 }
    env.chapters = { { chapterUid = 11, title = "First", chapterIdx = 1 },
        { chapterUid = 22, title = "Second", chapterIdx = 2 } }
    env.result = { path = env.path, selected_uids = { "11", "22" }, failed_uids = {}, cache_dir = env.cache_dir }
    function env:start(extra)
        local options = { silent_completion = true, on_start = function() self.start_notices = self.start_notices + 1 end,
            on_complete = function(ok, value) self.completions[#self.completions + 1] = { ok = ok, value = value } end }
        for key, value in pairs(extra or {}) do options[key] = value end
        return self.downloader:start(self.book, self.chapters, options.separate_chapters and "chapters" or "full", options)
    end
    function env:run_child()
        local pid = assert(self.worker.job).pid
        assert(self.callbacks[pid])()
        return pid
    end
    function env:poll()
        assert(table.remove(self.scheduled, 1), "worker poll was not scheduled")()
    end
    return env
end

local env = create_environment()
expect(env:start(), "manual download was rejected")
expect(env.child_runs == 0 and env.worker:busy(), "manual download did not defer work to the worker")
local handle = env.downloader._active_job.worker_handle
expect(handle and handle.options.preserve_queue and handle.options.book_id == "book",
    "manual download did not use the protected shared worker queue")
expect(env.prevented == 1 and env.start_notices == 1 and env.dialogs[1].shown,
    "manual worker did not acquire standby and show progress exactly once")
local pid = env:run_child()
env:poll()
expect(env.downloader._active_job and #env.completions == 0,
    "a result was applied before the child exited")
expect(env.dialogs[1].titles[#env.dialogs[1].titles]:find("Reusing cached chapter", 1, true),
    "worker source reuse progress was not delivered")
env.done[pid] = true; env:poll()
expect(env.child_runs == 1 and env.child_arguments.options.suffix == "full",
    "manual task did not reach the book worker entry")
expect(not env.downloader._active_job and not env.worker:busy() and env.allowed == 1 and env.dialogs[1].closed,
    "successful worker left an active job, standby guard, or dialog")
expect(#env.completions == 1 and env.completions[1].ok and env.completions[1].value == env.path,
    "private edition completion was not reported exactly once")
local saved = env.values.books.book
expect(saved.cached_full_book == env.path and saved.cache_dir == env.cache_dir and saved.progress == 88,
    "private edition registration lost its root or newer reading progress")
local descriptor = saved.annotation_documents[env.path]
expect(descriptor.clean and #descriptor.chapters == 2 and descriptor.chapters[2].chapterUid == 22,
    "private edition did not receive a complete clean annotation descriptor")
expect(saved.cached_chapters.unrelated == "/existing/chapter.epub", "cache merge removed an unrelated chapter")

env = create_environment()
env.fail_flush = true
expect(env:start(), "metadata failure fixture did not start")
local failed_handle = env.downloader._active_job.worker_handle
pid = env:run_child(); env.done[pid] = true; env:poll()
expect(not env.downloader._active_job and env.allowed == 1 and env.dialogs[1].closed,
    "metadata flush exception left download ownership or standby held")
expect(#env.completions == 1 and not env.completions[1].ok
    and tostring(env.completions[1].value):find("injected metadata flush failure", 1, true),
    "metadata flush exception was not reported once")
expect(exists(env.path), "metadata failure deleted the already published private edition")
env.fail_flush = false
expect(env:start(), "metadata failure prevented a subsequent download")
local replacement = env.downloader._active_job
local writes_before, auth_before = env.writes, env.auth_writes
failed_handle.options.on_done { ok = true, value = { path = env.path, selected_uids = { "11" },
    auth = { cookies = { session = "obsolete-session" } } } }
expect(env.downloader._active_job == replacement and env.writes == writes_before and env.auth_writes == auth_before,
    "late result mutated a replacement job or restored stale authentication")
env.fail_refresh = true
pid = env:run_child(); env.done[pid] = true; env:poll()
expect(#env.completions == 2 and env.completions[2].ok and not env.downloader._active_job,
    "optional UI refresh failure invalidated a completed download")

env = create_environment()
expect(env:start(), "cancellation fixture did not start")
local cancelled_handle = env.downloader._active_job.worker_handle
pid = env:run_child()
local drained = false
expect(env.downloader:cancelAll("cache_cleared", function() drained = true end), "active worker cancellation was rejected")
expect(not drained and env.downloader._active_job and env.allowed == 0,
    "cancel released ownership before the writer exited")
env.done[pid] = true; env:poll()
expect(drained and not env.downloader._active_job and env.allowed == 1,
    "cancelled worker did not finish draining after exit")
expect(env.dialogs[1].closed, "cancelAll left the download progress dialog open")
expect(#env.completions == 1 and not env.completions[1].ok and env.completions[1].value == "cache_cleared",
    "cancelled worker success was incorrectly registered")
expect(env.values.books.book.cached_full_book == nil and env.writes == 0,
    "cancelled worker published cache metadata")
cancelled_handle.options.on_done { ok = true, value = env.result }
expect(#env.completions == 1 and env.allowed == 1, "duplicate late completion released resources twice")

env = create_environment()
local chapter_path = env.path:gsub("book%.epub$", "chapter.epub")
write(chapter_path, "second private chapter")
env.result.chapter_paths = { ["11"] = env.path, ["22"] = chapter_path }
expect(env:start { separate_chapters = true }, "separate chapter worker did not start")
pid = env:run_child(); env.done[pid] = true; env:poll()
saved = env.values.books.book
expect(saved.cached_chapters["11"] == env.path and saved.cached_chapters["22"] == chapter_path,
    "separate private chapter paths were not registered")
expect(saved.annotation_documents[env.path].chapters[1].chapterUid == 11
    and saved.annotation_documents[chapter_path].chapters[1].chapterUid == 22,
    "separate private EPUBs did not receive their own chapter descriptors")
expect(saved.cached_full_book == nil, "selected chapters were registered as a complete book")

-- A current UI callback publishes a private candidate under a unique flat
-- filename, then updates the receipt and descriptors to that public path.
env = create_environment()
local previous_edition = env.cache_dir .. "/previous-edition.epub"
write(previous_edition, "previous complete edition")
env.values.books.book.cached_full_book = previous_edition
env.result.publication_key = "publication-success"
local receipt_updates, store_closes, receipt = 0, 0
env.downloader.download_store_factory = function(settings, book)
    expect(settings == env.settings and book == env.book, "publication store received a different job context")
    return { book_dir = env.cache_dir, putPublication = function(_, key, value)
        receipt_updates = receipt_updates + 1
        receipt = { key = key, path = value.path, cache_dir = value.cache_dir }
        expect(exists(value.path) and not exists(env.path), "receipt was updated before the private candidate rename")
        return true
    end, close = function() store_closes = store_closes + 1 end }
end
expect(env:start(), "flat publication fixture did not start")
pid = env:run_child(); env.done[pid] = true; env:poll()
saved = env.values.books.book
local published_path = saved.cached_full_book
expect(published_path and published_path ~= env.path and published_path ~= previous_edition
    and published_path:match("^(.*)/[^/]+$") == env.cache_dir and exists(published_path),
    "private candidate was not published as a unique flat EPUB")
expect(not exists(env.path) and exists(previous_edition), "flat publication retained its candidate or removed an older edition")
expect(receipt_updates == 1 and store_closes == 1 and receipt and receipt.key == "publication-success"
    and receipt.path == published_path and receipt.cache_dir == env.cache_dir,
    "flat publication receipt was not updated and closed exactly once")
expect(saved.annotation_documents and saved.annotation_documents[published_path]
    and not saved.annotation_documents[env.path]
    and saved.annotation_documents[published_path].chapters[2].chapterUid == 22,
    "annotation descriptor used the obsolete candidate path")
expect(#env.completions == 1 and env.completions[1].ok and env.completions[1].value == published_path,
    "successful flat publication returned an obsolete candidate path")

-- A receipt write failure rolls every renamed chapter back into its private
-- attempt and leaves the previous registered edition available for reading.
env = create_environment()
previous_edition = env.cache_dir .. "/previous-edition.epub"
write(previous_edition, "previous complete edition")
env.values.books.book.cached_full_book = previous_edition
local rollback_chapter = env.path:gsub("book%.epub$", "chapter.epub")
write(rollback_chapter, "second candidate chapter")
env.result.chapter_paths = { ["11"] = env.path, ["22"] = rollback_chapter }
env.result.publication_key = "publication-failure"
receipt_updates, store_closes = 0, 0
local attempted_paths = {}
env.downloader.download_store_factory = function()
    return { book_dir = env.cache_dir, putPublication = function(_, _, value)
        receipt_updates = receipt_updates + 1
        for _, path in pairs(value.chapter_paths) do attempted_paths[#attempted_paths + 1] = path end
        expect(#attempted_paths == 2 and not exists(env.path) and not exists(rollback_chapter),
            "receipt failure fixture did not rename both chapter candidates")
        return nil, "injected publication receipt failure"
    end, close = function() store_closes = store_closes + 1 end }
end
expect(env:start { separate_chapters = true }, "publication rollback fixture did not start")
pid = env:run_child(); env.done[pid] = true; env:poll()
saved = env.values.books.book
expect(receipt_updates == 1 and store_closes == 1 and exists(env.path) and exists(rollback_chapter),
    "receipt failure did not close the store and restore every private candidate")
local restored_candidates = env.result.path == env.path and env.result.chapter_paths["22"] == rollback_chapter
for _, path in ipairs(attempted_paths) do restored_candidates = restored_candidates and not exists(path) end
expect(restored_candidates, "receipt rollback left a flat candidate or mutated result path behind")
expect(saved.cached_full_book == previous_edition and exists(previous_edition)
    and saved.cached_chapters["11"] == nil and saved.cached_chapters["22"] == nil
    and not saved.annotation_documents and env.writes == 0,
    "failed receipt publication changed registered book metadata")
expect(#env.completions == 1 and not env.completions[1].ok
    and tostring(env.completions[1].value):find("injected publication receipt failure", 1, true),
    "publication receipt failure was not reported exactly once")
expect(not env.downloader._active_job and env.allowed == 1 and env.dialogs[1].closed,
    "publication receipt failure retained download ownership or standby")

-- Queued completion callbacks also cancel dependent state such as a pending
-- cloud-progress jump. A callback failure must not leave the active writer live.
env = create_environment()
assert(env.downloader:start(env.book, { env.chapters[1] }, "chapter", { prefetch = true, single_chapter = true }))
env:poll()
pid = assert(env.worker.job).pid
local queued_completions = 0
expect(env:start { on_complete = function(ok, reason)
    queued_completions = queued_completions + 1
    expect(not ok and reason == "cache_cleared", "queued cancellation lost its failure reason")
    error("injected queued completion failure")
end }, "manual job was not queued behind prefetch")
local pending = assert(env.downloader._pending_start)
env.downloader._scheduled_start = { pending = pending }
expect(env.downloader:cancelAll("cache_cleared"), "queued callback failure interrupted active cancellation")
expect(queued_completions == 1 and env.downloader._pending_start == nil
    and env.downloader._scheduled_start == nil, "the same pending job was notified twice or was not revoked")
expect(env.downloader._active_job.cancelled and env.worker.job.cancel_requested_at ~= nil,
    "throwing queued callback left the active worker uncancelled")
env.done[pid] = true; env:poll()
expect(not env.downloader._active_job and env.allowed == 1, "active prefetch did not drain after queued callback failure")
env.downloader:cancelAll("cache_cleared")
expect(queued_completions == 1, "repeated cancelAll notified an already discarded request")

-- Pending work already moved into its delayed start slot still receives one
-- terminal notification when no active writer remains.
env = create_environment()
assert(env.downloader:start(env.book, { env.chapters[1] }, "chapter", { prefetch = true, single_chapter = true }))
env:poll()
pid = assert(env.worker.job).pid
assert(env:start())
env.done[pid] = true; env:poll()
expect(env.downloader._scheduled_start and not env.downloader._active_job,
    "scheduled cancellation fixture did not reach its delayed start slot")
env.downloader:cancelAll("account_changed")
expect(#env.completions == 1 and not env.completions[1].ok and env.completions[1].value == "account_changed",
    "scheduled-only cancellation lost its completion notification")
env:poll()
expect(not env.worker:busy() and not env.downloader._active_job and env.child_runs == 0
    and #env.completions == 1, "a revoked scheduled job launched or notified twice")

-- Exercise the actual group/coordinator entry selected by manual downloads.
env = create_environment(true)
env.values.cache.chapter_download_concurrency = 1
expect(env:start(), "configured serial download did not start")
expect(env.worker.job.pid and not env.worker.job.group, "serial mode added unnecessary group children")
pid = env:run_child(); env.done[pid] = true; env:poll()
expect(env.completions[1].ok and env.child_runs == 1, "configured serial mode lost its compatible worker path")

local BookWorker = require("weread.lib.book_download_worker")
function BookWorker.prepare(_settings, book, chapters)
    environment.phases.prepare = (environment.phases.prepare or 0) + 1
    local plan = { book = book, jobs = {} }
    for index, chapter in ipairs(chapters) do
        plan.jobs[index] = { ordinal = index, key = "key" .. chapter.chapterUid,
            chapter_uid = tostring(chapter.chapterUid), cached = false }
    end
    return plan
end
function BookWorker.acquire(settings, client, _book, chapter, options)
    environment.phases.acquire = (environment.phases.acquire or 0) + 1
    expect(client.settings == settings and settings ~= environment.settings,
        "group child did not receive its private settings/client")
    expect(settings:get("cookies").session == "parent-session", "parallel child inherited another child's cookie update")
    if environment.acquire_failure then
        local failure = environment.acquire_failure(chapter)
        if failure then return failure end
    end
    settings:set("cookies", { session = "private-acquisition" })
    return { status = "ready", key = options.key, chapter_uid = tostring(chapter.chapterUid),
        css_path = "/fixture/style.css", content_format = "epub" }
end
function BookWorker.commit(_settings, _book, chapter, ready)
    environment.phases.commit = (environment.phases.commit or 0) + 1
    return { key = ready.key, chapter_uid = tostring(chapter.chapterUid), css_path = ready.css_path,
        content_format = ready.content_format, resources_complete = true }
end
function BookWorker.assemble(settings, _client, _book, chapters)
    environment.phases.assemble = (environment.phases.assemble or 0) + 1
    expect(settings:get("cookies").session == "parent-session", "assembly inherited an acquisition's private cookies")
    environment.result.selected_uids = {}
    for _, chapter in ipairs(chapters) do
        environment.result.selected_uids[#environment.result.selected_uids + 1] = tostring(chapter.chapterUid)
    end
    environment.result.auth = { cookies = { session = "final-assembly" } }
    return environment.result
end
local function group_environment(concurrency)
    local result = create_environment(true)
    result.phases, result.executed = {}, {}
    result.book.cache_dir, result.settings.cache_dir, result.settings.data_dir = result.cache_dir, result.cache_dir, root
    result.values.cache.chapter_download_concurrency = concurrency
    result.chapters = {}
    for index = 1, 8 do result.chapters[index] = { chapterUid = index, title = "Chapter " .. index } end
    function result:group_step()
        for child_pid, callback in pairs(self.callbacks) do
            if not self.executed[child_pid] and not self.done[child_pid] then
                self.executed[child_pid] = true
                callback()
                self.done[child_pid] = true
            end
        end
        if self.worker.job and self.worker.job.group then
            self.peak = math.max(self.peak or 0, self.worker.job.group.active)
        end
        self:poll()
    end
    function result:finish_group()
        local steps = 0
        while self.worker:busy() do
            steps = steps + 1
            assert(steps < 300, "manual group did not finish")
            self:group_step()
        end
    end
    return result
end
env = group_environment()
expect(env:start(), "default group download did not start")
expect(env.worker.job.group and env.downloader._active_job.download_concurrency == 5
    and env.worker.job.request.options.concurrency == 5, "manual default did not select a five-slot group")
env:finish_group()
expect(env.peak == 5 and env.phases.acquire == 8 and env.phases.commit == 8 and env.phases.assemble == 1,
    "manual group did not use five slots and one final assembly")
expect(#env.completions == 1 and env.completions[1].ok and env.allowed == 1 and env.dialogs[1].closed,
    "successful group did not finalize the downloader exactly once")
expect(env.values.books.book.cached_full_book == env.path and env.auth_writes == 1
    and env.values.cookies.session == "final-assembly", "final assembly did not publish with the existing auth fence")

env = group_environment(3)
expect(env:start(), "configured group download did not start")
env.values.cache.chapter_download_concurrency = 5
env.values.cookies = { session = "new-parent-session" }
env:finish_group()
expect(env.peak == 3 and env.phases.acquire == 8, "running group adopted a later concurrency setting")
expect(env.auth_writes == 0 and env.values.cookies.session == "new-parent-session",
    "old group result overwrote newer parent authentication")

env = group_environment()
local reporting = true
env.downloader.is_reporting = function() return reporting end
expect(env:start(), "download did not accept waiting for an existing report")
expect(env.downloader:isManualDownloading() and not env.worker:busy() and env.next_pid == 10,
    "chapter workers overlapped the existing reporting subprocess")
env.values.cache.chapter_download_concurrency = 1
reporting = false
env:poll()
env:finish_group()
expect(env.completions[1].ok and env.prevented == 1 and env.allowed == 1,
    "waiting for reporting duplicated standby ownership or did not resume")
expect(env.peak == 5, "a running report-wait job adopted a later concurrency setting")

env = group_environment()
env.downloader.is_reporting = function() return true end
expect(env:start(), "report-wait cancellation fixture did not start")
env.downloader:cancelAll("cancelled")
env:poll()
expect(not env.downloader:isManualDownloading() and not env.worker:busy()
    and env.next_pid == 10 and env.allowed == 1,
    "cancelling the report wait started work or retained standby")

env = group_environment()
env.downloader.is_reporting = function() return true end
expect(env:start(), "report-wait timeout fixture did not start")
env.downloader._active_job.report_wait_started = os.time() - 211
env:poll()
expect(not env.downloader:isManualDownloading() and #env.completions == 1
    and not env.completions[1].ok and env.next_pid == 10,
    "a reporting subprocess that never exits blocked the downloader indefinitely")

env = group_environment()
expect(env:start(), "group cancellation fixture did not start")
local steps = 0
while env.worker.job.group.active < 5 do
    steps = steps + 1
    assert(steps < 100, "group cancellation fixture never opened five slots")
    env:group_step()
end
local group_drained = false
expect(env.downloader:cancelAll("cache_cleared", function() group_drained = true end), "group cancellation was rejected")
expect(not group_drained and env.allowed == 0, "group drain callback ran before all writers exited")
env:finish_group()
expect(group_drained and #env.completions == 1 and not env.completions[1].ok and env.allowed == 1,
    "cancelled group did not finalize and drain once")
expect(not env.values.books.book.cached_full_book and env.phases.assemble == nil and env.auth_writes == 0,
    "cancelled group published a file or credentials")

-- Known pause metadata drives translated presentation without changing the
-- original callback error string or exposing a source filename to the reader.
local original_reader_settings = G_reader_settings
rawset(_G, "G_reader_settings", { readSetting = function() return "zh_CN" end })
local real_i18n = dofile("weread/lib/i18n.lua")
local shim_i18n = require("weread.lib.i18n")
local original_translate = shim_i18n.tr
shim_i18n.tr = real_i18n.tr
local pause_key = "Download paused. Completed chapters have been saved.\nPlease cache the book again later to continue."
local login_key = "Please check your login and book access before continuing."
expect(real_i18n.tr(pause_key) ~= pause_key and real_i18n.tr(login_key) ~= login_key,
    "download pause or account guidance has no Chinese translation")
local raw_http_error = "/fixture/weread/lib/content.lua:1635: /web/book/chapter/t_0 failed: HTTP 503"
env = group_environment(5)
local failing_requests, callback_arguments = 0, nil
env.acquire_failure = function(chapter)
    if chapter.chapterUid ~= 4 then return nil end
    failing_requests = failing_requests + 1
    return { status = "failed", error = raw_http_error,
        diagnostic = { status = 503, kind = "http_status", retryable = true } }
end
expect(env:start { on_complete = function(...)
    callback_arguments = { count = select("#", ...), ... }
end }, "HTTP pause presentation fixture did not start")
env:finish_group()
local message = env.infos[#env.infos] or ""
expect(failing_requests == 3 and env.phases.assemble == nil and not env.downloader._active_job,
    "pause presentation changed retry bounds or job teardown")
expect(callback_arguments and callback_arguments.count == 2 and callback_arguments[1] == false
    and callback_arguments[2] == raw_http_error, "pause presentation changed the on_complete error contract")
expect(message:find(real_i18n.tr(pause_key), 1, true) and message:find("HTTP 503", 1, true)
    and not message:find("content.lua", 1, true) and not message:find("/web/", 1, true),
    "HTTP pause did not explain recovery or exposed an internal source path")
expect(env.allowed == 1 and env.dialogs[1].closed and (env.phases.commit or 0) > 0,
    "pause presentation lost committed work or retained a download dialog")

env = create_environment()
env.serial_pause = { stage = "paused", index = 1, total = 2, pause = true,
    http_status = 503, error_kind = "http_status", error = raw_http_error }
expect(env:start(), "serial pause presentation fixture did not start")
pid = assert(env.worker.job).pid
local pause_written_during_reap = false
local original_is_done = env.worker.runner.is_done
env.worker.runner.is_done = function(candidate)
    if candidate == pid and not pause_written_during_reap then
        -- The parent has already read the progress file in this poll. Finish
        -- the child now so its last paused state only exists during waitpid.
        pause_written_during_reap = true
        env.callbacks[pid]()
        env.done[pid] = true
    end
    return original_is_done(candidate)
end
env:poll()
message = env.infos[#env.infos] or ""
expect(pause_written_during_reap and message:find(real_i18n.tr(pause_key), 1, true)
    and message:find("HTTP 503", 1, true) and not message:find("content.lua", 1, true),
    "serial worker pause written during reap was not retained for presentation")
expect(#env.completions == 1 and not env.completions[1].ok
    and tostring(env.completions[1].value):find(raw_http_error, 1, true),
    "serial pause presentation discarded the original diagnostic error")

env = group_environment(5)
local raw_auth_error = "/fixture/content.lua:99: authentication failed"
env.acquire_failure = function()
    return { status = "failed", error = raw_auth_error,
        diagnostic = { status = 401, kind = "authentication", retryable = false } }
end
expect(env:start(), "account pause presentation fixture did not start")
env:finish_group()
message = env.infos[#env.infos] or ""
expect(env.phases.acquire == 1 and message:find(real_i18n.tr(login_key), 1, true)
    and message:find("HTTP 401", 1, true) and not message:find("content.lua", 1, true),
    "account pause lacked safe guidance or retried an authentication rejection")
local unknown_api = env.downloader:pauseMessage({ pause = true, http_status = 200,
    error_kind = "api_error", api_code = -10102, error = "/fixture/content.lua:1: API -10102" })
expect(unknown_api == real_i18n.tr(pause_key), "unknown API pause was mislabeled as HTTP failure or authentication loss")
shim_i18n.tr = original_translate
rawset(_G, "G_reader_settings", original_reader_settings)

assert(root:match("^/tmp/"), "fixture cleanup must remain inside /tmp")
os.execute("rm -rf -- " .. quote(root))
print(("downloader_background_spec: %d checks, %d failures"):format(checks, failures))
assert(failures == 0, "downloader background regressions failed")
