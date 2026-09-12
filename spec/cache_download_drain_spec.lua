package.path = "./?.lua;./?/init.lua;" .. package.path

-- Cache removal uses the actual downloader, annotation scheduling methods,
-- and background worker. Filesystem deletion is recorded for ordering checks.
local checks, failures = 0, 0
local function expect(value, message)
    checks = checks + 1
    if not value then failures = failures + 1; print("FAIL " .. message) end
end
local execute = os.execute
local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
local function mkdir(path)
    local result = execute("mkdir -p -- " .. quote(path))
    assert(result == 0 or result == true)
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
    encode = function(value) sequence = sequence + 1; local key = "fixture-" .. sequence; codec[key] = value; return key end,
    decode = function(value) return codec[value] end,
} end
local logger = { info = function() end, warn = function() end, err = function() end }
logger.scoped = function() return logger end
package.preload["weread.lib.logger"] = function() return logger end
local function template(value, ...)
    local arguments = { ... }
    return (value:gsub("%%(%d+)", function(index) return tostring(arguments[tonumber(index)] or "") end))
end
package.preload["weread.lib.plugin_util"] = function() return {
    tr = function(value) return value end, T = template, log_error = tostring,
    display_error = tostring, file_exists = exists,
} end
package.preload["ffi/util"] = function() return { template = template } end
package.preload["weread.lib.footnotes"] = function() return {} end
package.preload["weread.lib.scan"] = function() return {} end
package.preload["weread.lib.annotation_chapters"] = function() return {} end
package.preload["weread.lib.i18n"] = function() return { tr = function(value) return value end } end
for _, name in ipairs({ "confirmbox", "buttondialog", "pathchooser" }) do
    package.preload["ui/widget/" .. name] = function() return { new = function(_, options) return options end } end
end
package.preload["device"] = function() return {
    isKindle = function() return false end, isKobo = function() return false end,
    isCervantes = function() return false end,
} end
package.preload["pluginshare"] = function() return {} end
local manager = {
    scheduleIn = function(_, _, callback) environment.scheduled[#environment.scheduled + 1] = callback end,
    preventStandby = function() end, allowStandby = function() end, show = function() end,
}
package.preload["ui/uimanager"] = function() return manager end
package.preload["ui/time"] = function() return { now = function() return 1000 end } end
package.preload["libs/libkoreader-lfs"] = function() return {
    attributes = function(path, field)
        if path == environment.temp_dir then return field and "directory" or { mode = "directory" } end
        if exists(path) then return field and "file" or { mode = "file" } end
    end,
    mkdir = function(path) mkdir(path); return true end,
} end
package.preload["weread.ui.download_dialog"] = function() return { new = function(_, options)
    return { options = options, show = function() end, close = function() end,
        setTitle = function() end, reportProgress = function() end }
end } end
package.preload["weread.lib.chapter_prefetch_worker"] = function() return {
    run = function() error("drain fixtures must not execute acquisition") end,
} end
package.preload["weread.lib.book_download_worker"] = function() return {
    run = function() error("drain fixtures must not execute acquisition") end,
} end
package.preload["readcollection"] = function() return {
    coll = { weread = {} }, removeItem = function() end, write = function() end,
} end

local Downloader = require("weread.lib.downloader")
local BackgroundWorker = require("weread.lib.background_worker")
local Cache = require("weread.ui.cache")
local Annotations = require("weread.ui.annotation_sync_controller")
local environment_count = 0
local function create_environment(enable_groups)
    environment_count = environment_count + 1
    local env = { scheduled = {}, callbacks = {}, done = {}, next_pid = 0, deletions = {},
        annotation_deletions = {}, completions = {}, annotation_launches = 0, clear_callbacks = 0 }
    environment = env
    env.temp_dir = root .. "/worker-" .. environment_count
    mkdir(env.temp_dir)
    env.books = { A = { book_id = "A", title = "Book A", cache_dir = root .. "/A" },
        B = { book_id = "B", title = "Book B", cache_dir = root .. "/B" } }
    env.settings = { cache_dir = root, get = function(_, key, default)
        if key == "books" then return env.books end
        if key == "cookies" or key == "cache" then return {} end
        return default
    end, set = function(_, key, value) if key == "books" then env.books = value end end,
        flush = function() end, is_cookie_configured = function() return true end }
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
    -- Keep the original single-worker cancellation coverage independent from
    -- the downloader's automatic selection of the newer group entry point.
    if not enable_groups then rawset(env.worker, "startGroup", false) end
    env.downloader = Downloader:new { settings = env.settings, client = {}, background_worker = env.worker,
        require_login = function() return true end, is_connected = function() return true end,
        run_online_task = function(_, callback) callback(); return true end,
        refresh_ui = function() end, refresh_shelf = function() end,
        show_info = function() end, show_transient = function() end,
        safe_callback = function(_, callback) return callback end, open_file = function() end }
    env.host = { settings = env.settings, downloader = env.downloader, prefetch_worker = env.worker,
        refreshShelfCacheIndicators = function() end,
        annotation_store = { clearBook = function(_, book_id)
            env.annotation_deletions[#env.annotation_deletions + 1] = {
                book_id = book_id, writer = env.worker.job and env.worker.job.request.options.book_id }
            return true
        end },
        _runAnnotationJob = function() env.annotation_launches = env.annotation_launches + 1 end }
    for key, value in pairs(Cache) do env.host[key] = value end
    env.host._cancelUnifiedAnnotationSync = Annotations._cancelUnifiedAnnotationSync
    env.host._schedulePendingAnnotations = Annotations._schedulePendingAnnotations
    function env:start(book_id, prefetch)
        return self.downloader:start(self.books[book_id], { { chapterUid = 1, title = "Chapter" } }, "chapter", {
            prefetch = prefetch == true, single_chapter = true, silent_completion = true,
            on_complete = function(ok, reason)
                self.completions[#self.completions + 1] = { book_id = book_id, ok = ok, reason = reason }
            end })
    end
    function env:poll(index) assert(table.remove(self.scheduled, index or 1), "expected a scheduled callback")() end
    function env:queue_annotation(book_id)
        local accepted, handle = self.worker:start { queue = true, preserve_queue = true, book_id = book_id,
            task = function() error("queued annotation should have been cancelled") end,
            on_done = function(result) self.queued_annotation_result = result end }
        assert(accepted); return handle
    end
    function env:pending_annotation(book_id)
        local pending = { context = { book_id = book_id, path = "/document" }, options = { prefetch = true } }
        self.host:_schedulePendingAnnotations(pending)
        self.host._annotation_pending_prefetch = pending
    end
    function env:cleared() self.clear_callbacks = self.clear_callbacks + 1 end
    return env
end
rawset(os, "execute", function(command)
    assert(command:match("^rm %-rf "), "unexpected cache filesystem command")
    environment.deletions[#environment.deletions + 1] = {
        command = command, writer = environment.worker.job and environment.worker.job.request.options.book_id }
    return 0
end)

-- Clearing B must revoke its queued intents even while an unrelated A writer
-- still owns the process slot. No B callback may recreate the cleared book.
local env = create_environment()
expect(env:start("A", true), "prefetch A did not start")
env:poll()
local active_pid = assert(env.worker.job).pid
expect(env:start("B", false) and env.downloader._pending_start,
    "manual B was not queued behind prefetch A")
env:queue_annotation("B")
env:pending_annotation("B")
expect(env.host:clearBookCache("B", function() env:cleared() end), "unrelated A writer blocked B cache removal")
expect(env.downloader._pending_start == nil and env.host._annotation_pending_start == nil
    and env.host._annotation_pending_prefetch == nil, "B pending download or annotation intent survived clear")
expect(env.queued_annotation_result and env.queued_annotation_result.cancelled
    and #(env.worker.pending_queue or {}) == 0, "queued B network writer survived clear")
expect(env.books.A and not env.books.B and env.clear_callbacks == 1 and #env.deletions == 1,
    "book-specific clear removed the wrong record or ran more than once")
env:poll(2)
expect(env.annotation_launches == 0, "revoked annotation scheduling recreated B work")
env.done[active_pid] = true; env:poll()
expect(not env.downloader._active_job and not env.downloader._scheduled_start and env.next_pid == 1,
    "cleared B was started after A exited")

-- Revoke a manual job already promoted from pending_start to scheduled_start.
env = create_environment()
assert(env:start("A", true)); env:poll()
active_pid = assert(env.worker.job).pid
assert(env:start("B", false))
env.done[active_pid] = true; env:poll()
expect(env.downloader._scheduled_start and not env.downloader._pending_start,
    "B was not scheduled after prefetch drain")
expect(env.host:clearBookCache("B"), "scheduled B could not be cleared")
expect(env.downloader._scheduled_start == nil, "scheduled_start survived targeted cache clear")
env:poll()
expect(env.next_pid == 1 and not env.worker:busy(), "revoked scheduled B still launched a writer")

-- An active writer for the target book must exit before either its files or
-- annotation database are removed, even when it ignores its cancellation file.
env = create_environment()
assert(env:start("B", false))
active_pid = assert(env.worker.job).pid
expect(env.host:clearBookCache("B", function() env:cleared() end) == false,
    "active B cache removal did not defer")
expect(env.worker:busy() and env.books.B and #env.deletions == 0 and #env.annotation_deletions == 0,
    "target files or database were deleted before writer exit")
env:poll()
expect(env.books.B and env.clear_callbacks == 0 and env.worker:busy(),
    "a still-running writer was treated as drained")
env.done[active_pid] = true; env:poll()
expect(not env.books.B and env.books.A and #env.deletions == 1 and env.clear_callbacks == 1,
    "target clear did not resume exactly once after writer exit")
expect(env.deletions[1].writer == nil and env.annotation_deletions[1].writer == nil,
    "cache deletion raced an active writer")
expect(not env.downloader._active_job and not env.worker:busy() and not env.worker.draining,
    "completed cache drain retained task ownership")

-- Clear-all also drains an annotation-owned process while the downloader is
-- merely queued; cancelling the queued downloader is not sufficient by itself.
env = create_environment()
local annotation_handle
local accepted
accepted, annotation_handle = env.worker:start { book_id = "A",
    task = function() error("annotation fixture must not execute") end,
    on_done = function() env.host._external_annotation_sync = nil end }
assert(accepted)
active_pid = assert(env.worker.job).pid
env.host._external_annotation_sync = { context = { book_id = "A" }, worker_handle = annotation_handle }
assert(env:start("B", false))
env:pending_annotation("B")
expect(env.host:clearAllCache(function() env:cleared() end) == false, "clear-all did not defer behind annotation writer")
expect(env.downloader._active_job == nil and env.worker:busy() and env.worker.draining,
    "queued downloader cancellation incorrectly ended annotation draining")
expect(env.host._annotation_pending_start == nil and env.host._annotation_pending_prefetch == nil
    and #env.deletions == 0 and #env.annotation_deletions == 0, "clear-all left intents or deleted live cache files")
env:poll(2)
expect(env.annotation_launches == 0, "clear-all allowed a stale annotation schedule to run")
env.done[active_pid] = true; env:poll()
expect(next(env.books) == nil and #env.deletions == 2 and #env.annotation_deletions == 2
    and env.clear_callbacks == 1, "clear-all did not delete each book after drain")
expect(env.deletions[1].writer == nil and env.deletions[2].writer == nil and env.next_pid == 1,
    "clear-all raced or relaunched a child process")

-- A real group has no outer child PID. Its two direct writers may have ready
-- result files, but cache deletion must still wait for both process exits.
env = create_environment(true)
local group, child_handles, child_results, group_results = nil, {}, {}, {}
local group_started = env.worker:startGroup {
    book_id = "B", concurrency = 2, preserve_queue = true,
    start = function(current)
        group = current
        for number = 1, 2 do
            local index = number
            child_handles[index] = assert(current:submit {
                task = function(context)
                    context.emit { stage = "source", index = index }
                    return { chapter_uid = tostring(index), candidate = "ready-before-exit" }
                end,
                on_done = function(result) child_results[index] = result end,
            })
        end
    end,
    on_done = function(result)
        group_results[#group_results + 1] = result
        expect(env.books.B ~= nil and #env.deletions == 0,
            "cache deletion ran before the group completion callback")
    end,
}
expect(group_started and env.worker.job and env.worker.job.group == group,
    "the cache group fixture did not enter the real group coordinator")
env:poll()
local first_pid, second_pid = assert(child_handles[1].pid), assert(child_handles[2].pid)
expect(first_pid ~= second_pid and env.next_pid == 2, "the group did not launch two independent writers")
env.callbacks[first_pid](); env.callbacks[second_pid]()
expect(env.host:clearBookCache("B", function() env:cleared() end) == false,
    "group-owned cache removal did not defer")
expect(env.books.B and #env.deletions == 0 and #env.annotation_deletions == 0 and #group_results == 0,
    "ready result files were mistaken for exited group writers")
env.done[first_pid] = true
for _ = 1, 20 do
    if child_results[1] then break end
    env:poll()
end
expect(child_results[1] and not child_results[1].ok and child_results[1].cancelled,
    "cancelled group accepted the first writer's previously ready result")
expect(not child_results[2] and env.worker:busy() and env.books.B
    and #env.deletions == 0 and #env.annotation_deletions == 0 and env.clear_callbacks == 0,
    "cache was removed after only one group writer exited")
env.done[second_pid] = true
for _ = 1, 20 do
    if env.clear_callbacks == 1 then break end
    env:poll()
end
expect(child_results[2] and not child_results[2].ok and child_results[2].cancelled,
    "cancelled group accepted the second writer's previously ready result")
expect(#group_results == 1 and group_results[1].cancelled and group_results[1].error == "cache_cleared",
    "the drained group did not report cancellation exactly once")
expect(env.clear_callbacks == 1 and not env.books.B and env.books.A
    and #env.deletions == 1 and #env.annotation_deletions == 1,
    "group cache removal did not resume exactly once after all writers exited")
expect(env.deletions[1].writer == nil and env.annotation_deletions[1].writer == nil
    and not env.worker:busy(), "group cache deletion raced a live writer or retained task ownership")

rawset(os, "execute", execute)
assert(root:match("^/tmp/"), "fixture cleanup must remain inside /tmp")
execute("rm -rf -- " .. quote(root))
print(("cache_download_drain_spec: %d checks, %d failures"):format(checks, failures))
assert(failures == 0, "cache download drain regressions failed")
