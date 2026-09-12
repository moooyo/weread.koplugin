-- Linux process integration for the injected BackgroundWorker runner.
-- Uses real fork/waitpid/kill, synthetic tasks, and no network or credentials.
package.path = "./?.lua;" .. package.path
local ffi = require("ffi")
require("jit").off()
assert(ffi.os == "Linux", "this process integration spec requires Linux")
ffi.cdef[[
int fork(void); int getpid(void); int getppid(void);
int waitpid(int pid, int *status, int options); int kill(int pid, int signal);
void _exit(int status); int usleep(unsigned int microseconds);
struct timeval { long tv_sec; long tv_usec; };
int gettimeofday(struct timeval *tv, void *tz);
char *mkdtemp(char *template);
int mkdir(const char *path, unsigned int mode); int rmdir(const char *path);
int access(const char *path, int mode);
void *opendir(const char *path); int closedir(void *directory);
]]
local C = ffi.C
local parent_pid = tonumber(C.getpid())
local function now()
    local value = ffi.new("struct timeval[1]")
    assert(C.gettimeofday(value, nil) == 0)
    return tonumber(value[0].tv_sec) + tonumber(value[0].tv_usec) / 1000000
end
local template = ffi.new("char[?]", 64, "/tmp/weread-group-process-XXXXXX")
assert(C.mkdtemp(template) ~= nil)
local root = ffi.string(template)
local artifacts = {}
local function write(path, text)
    local file = assert(io.open(path, "wb"))
    assert(file:write(text)); assert(file:close())
end
local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a"); file:close(); return text
end
local function encode(value)
    if type(value) == "table" then
        local parts = {}
        for key, entry in pairs(value) do
            parts[#parts + 1] = "[" .. encode(key) .. "]=" .. encode(entry)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif type(value) == "string" then return string.format("%q", value)
    else return tostring(value) end
end
package.preload["json"] = function() return {
    encode = encode,
    decode = function(value) return assert(loadstring("return " .. value))() end,
} end
package.preload["ffi/util"] = function() return {
    isAndroid = function() return false end,
    usleep = function(value) C.usleep(value) end,
} end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.logger"] = function() return { warn = function() end } end
package.preload["libs/libkoreader-lfs"] = function() return {
    attributes = function(path, field)
        local directory = C.opendir(path)
        local mode
        if directory ~= nil then C.closedir(directory); mode = "directory"
        elseif C.access(path, 0) == 0 then mode = "file" end
        if mode then return field and mode or { mode = mode } end
    end,
    mkdir = function(path) return C.mkdir(path, 448) == 0 end,
    rmdir = function(path) return C.rmdir(path) == 0 end,
} end
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end
local events, event_sequence = {}, 0
local scheduler = {
    scheduleIn = function(_, delay, callback)
        event_sequence = event_sequence + 1
        events[#events + 1] = { at = now() + delay, callback = callback, order = event_sequence }
    end,
    unschedule = function(_, callback)
        for _, event in ipairs(events) do if event.callback == callback then event.cancelled = true end end
    end,
}
local function drive(predicate, timeout)
    local deadline = now() + (timeout or 5)
    while not predicate() do
        assert(now() < deadline, "real-process scheduler deadline exceeded")
        table.sort(events, function(a, b) return a.at == b.at and a.order < b.order or a.at < b.at end)
        local event = table.remove(events, 1)
        assert(event, "live process has no scheduled poll")
        local remaining = event.at - now()
        if remaining > 0 then C.usleep(math.ceil(remaining * 1000000)) end
        if not event.cancelled then event.callback() end
    end
end
local children, launched, active, peak, killed = {}, 0, 0, 0, 0
local runner = {
    run = function(callback)
        assert(tonumber(C.getpid()) == parent_pid, "attempted to fork a grandchild")
        io.stdout:flush(); io.stderr:flush()
        local pid = C.fork()
        assert(pid >= 0, "fork failed")
        if pid == 0 then
            local ok, err = xpcall(callback, debug.traceback)
            if not ok then io.stderr:write(tostring(err), "\n"); io.stderr:flush() end
            C._exit(ok and 0 or 70)
        end
        pid = tonumber(pid)
        children[pid] = { reaped = false }
        launched, active = launched + 1, active + 1
        peak = math.max(peak, active)
        return pid
    end,
    is_done = function(pid)
        local child = assert(children[pid])
        if child.reaped then return true end
        local status = ffi.new("int[1]")
        local result = C.waitpid(pid, status, 1)
        if result == 0 then return false end
        assert(result == pid, "waitpid failed or another component reaped the child")
        child.reaped, child.status = true, tonumber(status[0])
        active = active - 1
        return true
    end,
    terminate = function(pid)
        assert(not children[pid].reaped, "tried to kill an already reaped process")
        assert(C.kill(pid, 9) == 0, "SIGKILL failed")
        children[pid].killed = true
        killed = killed + 1
    end,
}
local function reaped(pids)
    for _, pid in ipairs(pids) do
        if not children[pid].reaped then return false end
        local status = ffi.new("int[1]")
        expect(C.waitpid(pid, status, 1) == -1 and ffi.errno() == 10,
            "callback ran before the OS confirmed child reaping")
    end
    return true
end
local function direct_children(pids)
    for _, pid in ipairs(pids) do
        local status = assert(read("/proc/" .. pid .. "/status"))
        expect(tonumber(status:match("PPid:%s*(%d+)")) == parent_pid,
            "a chapter process is not a direct child of the test UI process")
        local descendants = assert(read("/proc/" .. pid .. "/task/" .. pid .. "/children"))
        expect(not descendants:match("%d"), "a chapter worker created a grandchild")
    end
end
local Worker = require("weread.lib.background_worker")
local worker = Worker:new {
    temp_dir = root .. "/worker", scheduler = scheduler, runner = runner, now = now,
    poll_interval = 0.01, cancel_grace = 0.05, timeout = 5,
    min_available_kb = 64 * 1024,
    read_memory = function() return "MemAvailable: 1048576 kB\n" end,
}
local function launch_group(label, count, blocking)
    local pids, results, completed, outcome = {}, {}, 0, nil
    local release = root .. "/release-" .. label
    artifacts[#artifacts + 1] = release
    for index = 1, count do artifacts[#artifacts + 1] = root .. "/ready-" .. label .. "-" .. index end
    local ok, handle = worker:startGroup {
        concurrency = 5, preserve_queue = true, book_id = label,
        start = function(group)
            expect(tonumber(C.getpid()) == parent_pid, "group coordinator left the UI process")
            for index = 1, count do
                local number = index
                assert(group:submit {
                    on_launch = function(pid) pids[#pids + 1] = pid end,
                    task = function(context)
                        local pid, ppid, started_at = tonumber(C.getpid()), tonumber(C.getppid()), now()
                        write(root .. "/ready-" .. label .. "-" .. number, tostring(pid))
                        context.emit { stage = "synthetic", pid = pid, ppid = ppid }
                        if blocking then C.usleep(3000000)
                        else
                            local deadline = now() + 3
                            while not read(release) do
                                assert(now() < deadline, "barrier was never released")
                                C.usleep(5000)
                            end
                            C.usleep(20000)
                        end
                        return { number = number, pid = pid, ppid = ppid,
                            started_at = started_at, finished_at = now() }
                    end,
                    on_done = function(result)
                        completed = completed + 1
                        if result.ok then results[#results + 1] = result.value end
                        if completed == count and not blocking then group:finish({ ok = true }) end
                    end,
                })
            end
        end,
        on_done = function(result)
            expect(reaped(pids), "root group callback ran before every child was reaped")
            outcome = result
        end,
    }
    expect(ok and handle and worker.job.pid == nil, "group created an outer subprocess")
    local function ready()
        if #pids < 5 then return false end
        for index = 1, 5 do if not read(root .. "/ready-" .. label .. "-" .. index) then return false end end
        return true
    end
    drive(ready)
    expect(active == 5 and #pids == 5, "five synthetic chapter processes did not overlap")
    direct_children(pids)
    return { handle = handle, pids = pids, results = results, release = release,
        outcome = function() return outcome end }
end
local ok, err = xpcall(function()
    local success = launch_group("complete", 7, false)
    write(success.release, "release")
    drive(function() return success.outcome() ~= nil end)
    expect(success.outcome().ok and #success.results == 7, "successful group lost a child result")
    for _, result in ipairs(success.results) do
        expect(result.ppid == parent_pid and children[result.pid].status == 0,
            "serialized child result has the wrong parent or exit status")
    end
    expect(peak == 5 and active == 0, "successful group exceeded its limit or leaked children")

    local targeted = launch_group("targeted", 5, true)
    local other_done, target_exited = false, false
    assert(worker:start { queue = true, preserve_queue = true, book_id = "other-book",
        task = function() return { parent = tonumber(C.getppid()) } end,
        on_done = function(result) other_done = result.ok and result.value.parent == parent_pid end })
    worker:cancelAndWait(targeted.handle, "book_cleared", function()
        expect(reaped(targeted.pids), "targeted drain callback ran before waitpid reaped every child")
        target_exited = true
    end)
    expect(not target_exited and not other_done, "targeted cancellation completed before children exited")
    drive(function() return target_exited and other_done end)
    expect(targeted.outcome().cancelled and active == 0,
        "targeted cancellation did not drain or resume the other book")

    local all = launch_group("all", 5, true)
    local idle, queued_cancelled = false, false
    assert(worker:start { queue = true, preserve_queue = true, book_id = "queued-book",
        task = function() error("cancelAll allowed queued work to run") end,
        on_done = function(result) queued_cancelled = result.cancelled == true end })
    worker:cancelAll("account_changed", function()
        expect(reaped(all.pids) and active == 0 and not worker:busy(),
            "cancelAll idle callback ran before all direct children were reaped")
        idle = true
    end)
    expect(queued_cancelled and not idle, "cancelAll did not cancel the queue before draining children")
    drive(function() return idle end)
    expect(all.outcome().cancelled and killed == 10, "non-cooperative children were not killed and reaped")
    local restarted = false
    assert(worker:start { book_id = "after-drain", task = function() return true end,
        on_done = function(result) restarted = result.ok and result.value end })
    drive(function() return restarted end)
    expect(active == 0 and launched == 19 and peak == 5, "group lifecycle leaked or oversubscribed processes")
end, debug.traceback)
-- Test failures must not leave live children in the remote environment.
for pid, child in pairs(children) do
    if not child.reaped then
        C.kill(pid, 9)
        local status = ffi.new("int[1]")
        while C.waitpid(pid, status, 0) == -1 and ffi.errno() == 4 do end
    end
end
for _, path in ipairs(artifacts) do os.remove(path) end
C.rmdir(root .. "/worker"); C.rmdir(root)
assert(ok, err)
print(string.format("background_group_process_spec: %d checks; UI pid=%d direct children=%d peak=%d SIGKILL+reap=%d; real Linux processes, no network", checks, parent_pid, launched, peak, killed))