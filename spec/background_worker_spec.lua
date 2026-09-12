package.path = "./?.lua;" .. package.path

local temp_dir = "/tmp/weread-background-worker-spec"
os.execute("mkdir -p " .. temp_dir)

local encoded, sequence = {}, 0
package.preload["json"] = function()
    return {
        encode = function(value)
            sequence = sequence + 1
            local key = "encoded-" .. tostring(sequence)
            encoded[key] = value
            return key
        end,
        decode = function(key) return encoded[key] end,
    }
end
package.preload["ffi/util"] = function()
    return { isAndroid = function() return false end }
end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function() end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            if path == temp_dir then return field and "directory" or { mode = "directory" } end
            local file = io.open(path, "rb")
            if not file then return nil end
            file:close()
            return field and "file" or { mode = "file" }
        end,
        mkdir = function(path)
            os.execute("mkdir -p " .. path)
            return true
        end,
    }
end

local BackgroundWorker = require("weread.lib.background_worker")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local scheduled, callbacks, done, terminated = {}, {}, {}, {}
local next_pid, clock = 200, 1000
local runner = {
    run = function(callback)
        next_pid = next_pid + 1
        callbacks[next_pid] = callback
        done[next_pid] = false
        return next_pid
    end,
    is_done = function(pid) return done[pid] == true end,
    terminate = function(pid)
        terminated[pid] = true
        done[pid] = true
    end,
}
local scheduler = {
    scheduleIn = function(_self, _delay, callback)
        scheduled[#scheduled + 1] = callback
    end,
}
local function new_worker(memory_kb)
    return BackgroundWorker:new {
        temp_dir = temp_dir,
        runner = runner,
        scheduler = scheduler,
        now = function() return clock end,
        read_memory = function()
            return "MemAvailable: " .. tostring(memory_kb) .. " kB\n"
        end,
        min_available_kb = 64 * 1024,
    }
end
local function poll()
    local callback = table.remove(scheduled, 1)
    expect(callback ~= nil, "worker did not schedule a poll")
    callback()
end

expect(BackgroundWorker.available_memory_kb(
    "MemFree: 10 kB\nBuffers: 20 kB\nCached: 30 kB\n") == 60,
    "legacy kernels must derive available memory")

local worker = new_worker(256 * 1024)
local progress, result
local started, handle = worker:start {
    task = function(context)
        context.emit { stage = "source", current = 2, count = 5 }
        return { path = "/tmp/book.epub" }
    end,
    on_progress = function(value) progress = value end,
    on_done = function(value) result = value end,
}
expect(started and handle and worker:busy(), "worker did not start")
callbacks[201]()
done[201] = true
poll()
expect(progress and progress.current == 2 and progress.count == 5,
    "progress file was not delivered")
expect(result and result.ok and result.value.path == "/tmp/book.epub",
    "result file was not delivered")
expect(not worker:busy(), "completed child was not cleared")

local first_done, second_done = false, false
local first_ok, first = worker:start {
    task = function() return "first" end,
    on_done = function(value) first_done = value.ok end,
}
local second_ok, second = worker:start {
    queue = true,
    task = function() return "second" end,
    on_done = function(value) second_done = value.ok end,
}
expect(first_ok and second_ok and first ~= second,
    "one pending task was not accepted")
callbacks[202](); done[202] = true; poll()
expect(first_done and worker:busy(), "pending task did not start after reaping")
callbacks[203](); done[203] = true; poll()
expect(second_done and not worker:busy(), "pending task did not finish")

local cancel_result
local cancel_ok, cancel_handle = worker:start {
    task = function() return "never run" end,
    on_done = function(value) cancel_result = value end,
}
expect(cancel_ok and worker:cancel(cancel_handle, "document_closed"),
    "active task did not accept cancellation")
clock = clock + 6
poll()
expect(terminated[204] and cancel_result and cancel_result.cancelled
    and cancel_result.error == "document_closed",
    "cancel grace did not terminate and report the task")

local launches_before = next_pid
local low_result
local low = new_worker(32 * 1024)
local low_ok, low_err = low:start {
    task = function() return true end,
    on_done = function(value) low_result = value end,
}
expect(not low_ok and low_err == "low_memory" and next_pid == launches_before,
    "64 MB gate still attempted to fork")
expect(low_result and low_result.available_kb == 32 * 1024,
    "low-memory result omitted available memory")

local order = {}
local durable = new_worker(256 * 1024)
local function task(name, preserve, replace)
    return { queue = true, preserve_queue = preserve, replace_active = replace,
        task = function() return name end,
        on_done = function(value) if value.ok then order[#order + 1] = value.value end end }
end
assert(durable:start(task("manual", true)))
assert(durable:start(task("second", true)))
assert(durable:start(task("third", true)))
assert(durable:start(task("prefetch", false, true)))
expect(not durable.job.cancel_requested_at, "prefetch interrupted a protected manual task")
expect(#durable.pending_queue == 2, "durable queue replaced an accepted task")
for _i = 1, 4 do
    local pid = durable.job.pid
    callbacks[pid](); done[pid] = true; poll()
end
expect(table.concat(order, ",") == "manual,second,third,prefetch", "durable queue was not FIFO")

local drained, queued_cancelled = false, false
assert(durable:start(task("cancel-active", true)))
local active_pid = durable.job.pid
assert(durable:start { queue = true, preserve_queue = true,
    task = function() return "never" end,
    on_done = function(value) queued_cancelled = value.cancelled end })
durable:cancelAll("cache_cleared", function()
    expect(not durable:busy(), "drain callback ran before child exit")
    drained = true
end)
expect(queued_cancelled and not drained, "drain did not cancel queued tasks before waiting")
local accepted, rejection = durable:start(task("late", true))
expect(not accepted and rejection == "worker_draining", "draining worker admitted new work")
clock = clock + 6; poll()
expect(drained and terminated[active_pid], "drain did not reap the active child")

local replaced, nested
assert(durable:start(task("outer", false)))
assert(durable:start { queue = true, task = function() return "old-pending" end,
    on_done = function()
        local ok
        ok, nested = durable:start(task("nested", false))
        assert(ok)
    end })
assert(durable:start { queue = true, task = function() return "new-pending" end,
    on_done = function(value) replaced = value.error == "replaced" end })
expect(replaced and durable.pending == nested, "reentrant callback lost a pending request")
durable:cancelAll("finished")
clock = clock + 6; poll()

local one_exited = false
assert(durable:start(task("one-writer", true)))
local one = durable.job.request
assert(durable:start(task("unrelated", true)))
durable:cancelAndWait(one, "cache_cleared", function() one_exited = true end)
expect(not one_exited and #durable.pending_queue == 1, "targeted drain discarded an unrelated job")
clock = clock + 6; poll()
expect(one_exited and durable:busy(), "targeted drain did not resume an unrelated job")
local resumed_pid = durable.job.pid
callbacks[resumed_pid](); done[resumed_pid] = true; poll()
expect(order[#order] == "unrelated", "unrelated queued work did not complete")

local function synchronous_failure_fifo(mode)
    local queued = new_worker(256 * 1024)
    local fifo_order = {}
    local expected_error = mode == "unavailable" and "worker_unavailable"
        or (mode == "memory" or mode == "cooldown") and "low_memory"
        or "synthetic fork failure"
    local function restore()
        queued.runner = runner
        queued.memory_cooldown_until = nil
        queued.read_memory = function() return "MemAvailable: 262144 kB\n" end
    end
    local function arm_failure()
        if mode == "unavailable" then queued.runner = nil
        elseif mode == "memory" then
            queued.read_memory = function() return "MemAvailable: 32768 kB\n" end
        elseif mode == "cooldown" then queued.memory_cooldown_until = clock + 10
        else
            queued.runner = {
                run = function()
                    if mode == "throw" then error("synthetic fork failure", 0) end
                    return false, "synthetic fork failure"
                end,
                is_done = runner.is_done,
                terminate = runner.terminate,
            }
        end
    end
    local function record(name)
        return { queue = true, preserve_queue = true,
            task = function() return name end,
            on_done = function(value)
                if value.ok then fifo_order[#fifo_order + 1] = value.value end
            end }
    end
    assert(queued:start { task = function() return true end, on_done = arm_failure })
    assert(queued:start { queue = true, preserve_queue = true,
        task = function() error("failed request must not run") end,
        on_done = function(value)
            expect(not value.ok and value.error == expected_error,
                "synchronous failure was not delivered for " .. mode)
            restore()
            assert(queued:start(record("R")))
        end })
    assert(queued:start(record("Q")))
    for _index = 1, 3 do
        local pid = assert(queued.job).pid
        callbacks[pid](); done[pid] = true; poll()
    end
    expect(table.concat(fifo_order, ",") == "Q,R",
        "synchronous " .. mode .. " failure reordered queued tasks: " .. table.concat(fifo_order, ","))
    expect(not queued:busy(), "synchronous failure left the worker busy")
end

for _, mode in ipairs({ "return", "throw", "memory", "cooldown", "unavailable" }) do
    synchronous_failure_fifo(mode)
end

local initial_failure = new_worker(32 * 1024)
local retry_handle
local initially_started, initial_error = initial_failure:start {
    task = function() error("low-memory request must not run") end,
    on_done = function()
        initial_failure.read_memory = function() return "MemAvailable: 262144 kB\n" end
        local ok
        ok, retry_handle = initial_failure:start { queue = true, preserve_queue = true,
            task = function() return "retry" end }
        assert(ok)
    end,
}
expect(not initially_started and initial_error == "low_memory",
    "initial synchronous failure changed the start result")
expect(initial_failure.job and initial_failure.job.request == retry_handle,
    "completion callback's queued retry was not started")
local retry_pid = initial_failure.job.pid
callbacks[retry_pid](); done[retry_pid] = true; poll()
expect(not initial_failure:busy(), "retry did not release the completion barrier")

local nested_completion = new_worker(256 * 1024)
local nested_order = {}
assert(nested_completion:start {
    task = function() return true end,
    on_done = function()
        assert(nested_completion:start { queue = true, task = function() return "replaced" end,
            on_done = function(value) expect(value.error == "replaced", "replacement did not complete") end })
        assert(nested_completion:start { queue = true, task = function() return "replaceable" end,
            on_done = function(value) nested_order[#nested_order + 1] = value.value end })
        assert(nested_completion:start { queue = true, preserve_queue = true,
            task = function() return "durable" end,
            on_done = function(value) nested_order[#nested_order + 1] = value.value end })
        expect(nested_completion.job == nil,
            "nested completion admitted a writer before the outer callback returned")
    end,
})
for _index = 1, 3 do
    local pid = assert(nested_completion.job).pid
    callbacks[pid](); done[pid] = true; poll()
end
expect(table.concat(nested_order, ",") == "durable,replaceable",
    "nested completion did not preserve the outer admission barrier")

local function final_progress_race(mode)
    local final_worker = new_worker(256 * 1024)
    local delivery_order, final_progress, final_result = {}, nil, nil
    final_worker.runner = {
        run = runner.run,
        terminate = runner.terminate,
        is_done = function(pid)
            -- Publish after the parent's initial progress read, then report exit.
            if not done[pid] then callbacks[pid](); done[pid] = true end
            return true
        end,
    }
    assert(final_worker:start {
        task = function(context)
            context.emit { stage = "paused", pause = true, http_status = 503,
                error_kind = "http", error = "synthetic pause" }
            error("synthetic pause", 0)
        end,
        on_progress = function(value)
            delivery_order[#delivery_order + 1] = "progress"
            final_progress = value
            if mode == "callback_error" then error("synthetic progress callback error") end
        end,
        on_done = function(value)
            delivery_order[#delivery_order + 1] = "done"
            final_result = value
        end,
    })
    if mode == "already_read" then
        local pid = final_worker.job.pid
        callbacks[pid](); done[pid] = true
    end
    poll()
    expect(table.concat(delivery_order, ",") == "progress,done",
        "final progress was lost, repeated, or delivered after completion: " .. mode)
    expect(final_progress and final_progress.pause and final_progress.http_status == 503,
        "final progress omitted pause metadata")
    expect(final_result and not final_result.ok and type(final_result.error) == "string"
        and final_result.error:find("synthetic pause", 1, true) and not final_worker:busy(),
        "final progress changed the failure result or prevented retirement")
end

for _, mode in ipairs({ "exit_race", "already_read", "callback_error" }) do
    final_progress_race(mode)
end

print(("background_worker_spec: %d checks"):format(checks))
