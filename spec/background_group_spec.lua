package.path = "./?.lua;" .. package.path

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local temporary = os.tmpname()
os.remove(temporary)
assert(os.execute("mkdir -p " .. string.format("%q", temporary)) == 0)
local directories = { [temporary] = true }
local encoded, encoding_sequence = {}, 0
package.preload["json"] = function()
    return {
        encode = function(value)
            encoding_sequence = encoding_sequence + 1
            local key = "encoded-" .. tostring(encoding_sequence)
            encoded[key] = value
            return key
        end,
        decode = function(key) return encoded[key] end,
    }
end
package.preload["ffi/util"] = function()
    return { isAndroid = function() return false end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.logger"] = function() return { warn = function() end } end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            local mode = directories[path] and "directory"
            if not mode then
                local file = io.open(path, "rb")
                if file then file:close(); mode = "file" end
            end
            if mode then return field and mode or { mode = mode } end
        end,
        mkdir = function(path)
            local result = os.execute("mkdir -p " .. string.format("%q", path))
            directories[path] = result == 0
            return result == 0
        end,
        rmdir = function(path)
            directories[path] = nil
            return os.remove(path)
        end,
    }
end

local Worker = require("weread.lib.background_worker")
local environment_sequence = 0
local function environment()
    environment_sequence = environment_sequence + 1
    local env = {
        clock = os.time(), memory = 256 * 1024, events = {}, children = {},
        next_pid = 100, event_sequence = 0, peak = 0, auto_reap = true,
    }
    env.scheduler = {
        scheduleIn = function(_self, delay, callback)
            env.event_sequence = env.event_sequence + 1
            env.events[#env.events + 1] = { at = env.clock + delay,
                sequence = env.event_sequence, callback = callback }
        end,
        unschedule = function(_self, callback)
            for _, event in ipairs(env.events) do
                if event.callback == callback then event.cancelled = true end
            end
        end,
    }
    env.runner = {
        run = function(callback)
            assert(not env.in_child, "nested fork attempted")
            if env.launch_error then error(env.launch_error) end
            env.next_pid = env.next_pid + 1
            env.children[env.next_pid] = { callback = callback }
            local active = 0
            for _, child in pairs(env.children) do if not child.done then active = active + 1 end end
            env.peak = math.max(env.peak, active)
            return env.next_pid
        end,
        is_done = function(pid) return env.children[pid].done == true end,
        terminate = function(pid)
            env.children[pid].terminated = true
            if env.auto_reap then env.children[pid].done = true end
        end,
    }
    env.worker = Worker:new {
        temp_dir = temporary .. "/environment-" .. tostring(environment_sequence),
        scheduler = env.scheduler, runner = env.runner,
        now = function() return env.clock end,
        read_memory = function() return "MemAvailable: " .. tostring(env.memory) .. " kB\n" end,
    }
    function env:step()
        table.sort(self.events, function(left, right)
            if left.at == right.at then return left.sequence < right.sequence end
            return left.at < right.at
        end)
        local event = table.remove(self.events, 1)
        assert(event, "no scheduled event")
        self.clock = math.max(self.clock, event.at)
        if not event.cancelled then event.callback() end
    end
    function env:until_true(predicate, limit)
        for _index = 1, limit or 1000 do
            if predicate() then return end
            self:step()
        end
        assert(predicate(), "condition did not become true")
    end
    function env:run_child(pid, exited)
        local child = assert(self.children[pid])
        self.in_child = true
        child.callback()
        self.in_child = false
        child.ran = true
        if exited ~= false then child.done = true end
    end
    function env:all_reaped()
        for _, child in pairs(self.children) do if not child.done then return false end end
        return true
    end
    return env
end

local env = environment()
local group, root_result, root_done, launched = nil, nil, 0, false
local order, progress = {}, {}
local started, root_handle = env.worker:startGroup {
    concurrency = 5, preserve_queue = true, book_id = "book-one",
    on_launch = function(pid, memory)
        expect(pid == nil and memory == env.memory, "virtual group claimed an outer child PID")
        launched = true
    end,
    start = function(current)
        expect(launched, "group setup ran before on_launch")
        group = current
        group:emit { stage = "prepare" }
        for index = 1, 7 do
            local number = index
            assert(group:submit {
                task = function(context)
                    context.emit { number = number }
                    return number
                end,
                on_progress = function(state) group:emit { stage = "child", number = state.number } end,
                on_done = function(result)
                    assert(result.ok)
                    order[#order + 1] = result.value
                    if #order == 7 then group:finish({ ok = true, value = "group-done" }) end
                end,
            })
        end
    end,
    on_progress = function(state) progress[#progress + 1] = state end,
    on_done = function(result) root_done = root_done + 1; root_result = result end,
}
expect(started and env.worker.job.group == group and env.worker.job.pid == nil,
    "group did not occupy the shared root worker")
expect(root_handle.options.book_id == "book-one" and root_handle.options.preserve_queue,
    "group lost the root request metadata")
expect(env.next_pid == 100, "submit forked before returning the UI request handles")
local following
assert(env.worker:start { queue = true, preserve_queue = true,
    task = function() return "following" end, on_done = function(result) following = result end })
env:step()
expect(env.next_pid == 105 and env.peak == 5, "five slots did not launch from the UI together")
expect(#group.slots == 5 and group.slots[1].worker.temp_dir ~= group.slots[2].worker.temp_dir,
    "slots did not use separate private directories")
env:run_child(105)
env:run_child(102)
env:until_true(function() return env.next_pid == 107 end)
expect(root_result == nil and following == nil, "queued root work ran before the group finished")
for pid, child in pairs(env.children) do if not child.done then env:run_child(pid) end end
env:until_true(function() return root_result ~= nil end)
expect(root_result.ok and root_result.value == "group-done" and root_done == 1
    and root_result.task_token == root_handle.token,
    "group completion was missing or duplicated")
expect(#order == 7 and env.peak == 5, "out-of-order completions exceeded the slot cap or lost work")
for _, state in ipairs(progress) do expect(state.task_token == root_handle.token, "progress lost the root token") end
expect(env.worker.job and env.worker.job.pid == 108, "queued durable root work did not resume")
env:run_child(108)
env:until_true(function() return following ~= nil end)
expect(following.ok and not env.worker:busy(), "following root work did not finish")

env = environment()
env.auto_reap = false
local cancelled_children, delayed_ran, exited_callback = 0, false, false
root_result, group = nil, nil
started, root_handle = env.worker:startGroup {
    concurrency = 3, preserve_queue = true,
    start = function(current)
        group = current
        for _index = 1, 4 do
            group:submit {
                task = function() return "must-not-commit" end,
                on_done = function(result)
                    expect(not result.ok and result.cancelled, "cancelled group delivered a successful child")
                    cancelled_children = cancelled_children + 1
                end,
            }
        end
        group:defer(1, function() delayed_ran = true end)
    end,
    on_done = function(result) root_result = result end,
}
expect(started, "cancellation fixture did not start its group")
env:step()
env:run_child(101, false)
local next_result
assert(env.worker:start { queue = true, preserve_queue = true,
    task = function() return "unrelated" end, on_done = function(result) next_result = result end })
assert(env.worker:cancelAndWait(root_handle, "cache_cleared", function()
    expect(env:all_reaped(), "cache deletion was allowed before every group child exited")
    exited_callback = true
end))
expect(cancelled_children == 1 and not exited_callback, "queued child was not revoked before draining")
expect(group:cancelled() and group:submit { task = function() end } == nil,
    "cancelled group admitted new work")
env.clock = env.clock + 6
env:until_true(function()
    for _, child in pairs(env.children) do if not child.terminated then return false end end
    return true
end)
expect(root_result == nil and not exited_callback, "SIGKILL request was confused with a completed reap")
for _, child in pairs(env.children) do child.done = true end
env:until_true(function() return root_result ~= nil end)
expect(root_result.cancelled and root_result.error == "cache_cleared" and exited_callback,
    "targeted group drain lost its cancellation reason or exit callback")
expect(cancelled_children == 4 and not delayed_ran, "group cancellation missed a child or delayed callback")
expect(env.worker.job and env.worker.job.pid == 104, "targeted drain cancelled unrelated queued work")
env:run_child(104)
env:until_true(function() return next_result ~= nil end)

env = environment()
env.auto_reap = false
root_result, group = nil, nil
assert(env.worker:startGroup {
    concurrency = 2,
    start = function(current)
        group = current
        for _index = 1, 2 do group:submit { task = function() return true end } end
    end,
    on_done = function(result) root_result = result end,
})
env:step()
group:finish({ ok = false, error = "upstream_auth_failure", status = 401 })
expect(group:cancelled() and root_result == nil, "failure did not stop admission before reaping")
env.clock = env.clock + 6
env:until_true(function() return env.children[101].terminated and env.children[102].terminated end)
expect(root_result == nil, "failed group reported completion while children were alive")
for _, child in pairs(env.children) do child.done = true end
env:until_true(function() return root_result ~= nil end)
expect(not root_result.ok and root_result.error == "upstream_auth_failure"
    and root_result.status == 401 and not root_result.cancelled,
    "failure finish was rewritten as a user cancellation")

env = environment()
root_result, group = nil, nil
assert(env.worker:startGroup {
    concurrency = 2,
    start = function(current)
        group = current
        for _index = 1, 2 do current:submit { task = function() return true end } end
    end,
    on_done = function(result) root_result = result end,
})
env:step()
group:finish({ ok = true, value = "early-finish" })
env:run_child(101, false)
for _index = 1, 6 do env:step() end
expect(root_result == nil and not env.children[101].terminated and not env.children[102].terminated,
    "successful finish cancelled children or completed before exit")
env.children[101].done = true
env:run_child(102)
env:until_true(function() return root_result ~= nil end)
expect(root_result.ok and root_result.value == "early-finish", "successful drain lost its result")

env = environment()
env.auto_reap = false
local all_drained, pending_cancelled = false, false
root_result = nil
assert(env.worker:startGroup {
    concurrency = 2, preserve_queue = true,
    start = function(current)
        for _index = 1, 2 do current:submit { task = function() return true end } end
    end,
    on_done = function(result) root_result = result end,
})
env:step()
assert(env.worker:startGroup {
    queue = true, preserve_queue = true,
    start = function() error("cancelled queued group started") end,
    on_done = function(result) pending_cancelled = result.cancelled end,
})
env.worker:cancelAll("account_changed", function()
    expect(env:all_reaped() and not env.worker:busy(), "cancelAll idle callback ran with live children")
    all_drained = true
end)
local accepted, why = env.worker:startGroup { start = function() end }
expect(not accepted and why == "worker_draining" and pending_cancelled,
    "cancelAll did not cancel the queued group or block admission")
env.clock = env.clock + 6
env:until_true(function() return env.children[101].terminated and env.children[102].terminated end)
env.children[101].done = true
for _index = 1, 6 do env:step() end
expect(not all_drained and root_result == nil, "cancelAll waited for only one child")
env.children[102].done = true
env:until_true(function() return all_drained end)
expect(root_result.cancelled and root_result.error == "account_changed", "cancelAll lost the root cancellation")

for _, kind in ipairs({ "start", "root_progress", "child_progress", "child_done", "deferred", "launch", "slot_launch" }) do
    env = environment()
    local callback_result, current_group
    local label = "injected_" .. kind
    assert(env.worker:startGroup {
        concurrency = 2,
        on_launch = function() if kind == "launch" then error(label) end end,
        start = function(current)
            current_group = current
            if kind == "start" then error(label) end
            if kind == "root_progress" then current:emit { stage = "fail" }; return end
            if kind == "deferred" then current:defer(0.01, function() error(label) end); return end
            current:submit {
                task = function(context) context.emit { stage = "data" }; return true end,
                on_launch = function() if kind == "slot_launch" then error(label) end end,
                on_progress = function() if kind == "child_progress" then error(label) end end,
                on_done = function() if kind == "child_done" then error(label) end end,
            }
            current:submit { task = function() return true end }
        end,
        on_progress = function() if kind == "root_progress" then error(label) end end,
        on_done = function(result) callback_result = result end,
    })
    if kind == "child_progress" or kind == "child_done" then
        env:until_true(function() return env.next_pid == 102 end)
        env:run_child(101)
    end
    env:until_true(function() return callback_result ~= nil end)
    expect(not callback_result.ok and tostring(callback_result.error):find(label, 1, true)
        and env:all_reaped() and not env.worker:busy(), "callback error left the group stuck: " .. kind)
    if current_group then expect(current_group.finished, "failed group was not closed") end
end

env = environment()
root_result = nil
assert(env.worker:startGroup {
    concurrency = 5, memory_wait_seconds = 1, timeout = 10,
    start = function(current) current:submit { task = function() return true end } end,
    on_done = function(result) root_result = result end,
})
env.memory = 32 * 1024
env:until_true(function() return root_result ~= nil end)
expect(root_result.error == "low_memory" and env.next_pid == 100 and not env.worker:busy(),
    "zero-active low memory waited forever or still forked")

env = environment()
env.memory = 64 * 1024
local completed = 0
root_result = nil
assert(env.worker:startGroup {
    concurrency = 5,
    start = function(current)
        for _index = 1, 3 do
            current:submit {
                task = function() return true end,
                on_done = function(result)
                    assert(result.ok)
                    completed = completed + 1
                    if completed == 3 then current:finish({ ok = true }) end
                end,
            }
        end
    end,
    on_done = function(result) root_result = result end,
})
for index = 1, 3 do
    env:until_true(function() return env.next_pid == 100 + index end)
    expect(env.peak == 1, "low memory did not pause extra slot admission")
    env:run_child(100 + index)
end
env:until_true(function() return root_result ~= nil end)
expect(root_result.ok and completed == 3, "serial memory fallback lost queued work")

env = environment()
root_result = nil
assert(env.worker:startGroup {
    concurrency = 2, timeout = 1,
    start = function() end,
    on_done = function(result) root_result = result end,
})
env:until_true(function() return root_result ~= nil end)
expect(root_result.error == "worker_timeout" and not root_result.cancelled,
    "a coordinator that never finished bypassed the group idle timeout")

env = environment()
root_result = nil
assert(env.worker:startGroup {
    concurrency = 2,
    start = function(current)
        current:submit {
            task = function()
                local allowed, reason = env.worker:start { task = function() end }
                assert(not allowed and reason == "nested_worker_forbidden")
                local child_accepted = pcall(current.submit, current, { task = function() end })
                assert(not child_accepted, "child used a parent group method")
                return true
            end,
            on_done = function(result) current:finish(result) end,
        }
    end,
    on_done = function(result) root_result = result end,
})
env:until_true(function() return env.next_pid == 101 end)
env:run_child(101)
env:until_true(function() return root_result ~= nil end)
expect(root_result.ok and env.next_pid == 101, "group slot created a nested subprocess")

env = environment()
env.launch_error = "injected fork failure"
root_result = nil
assert(env.worker:startGroup {
    start = function(current) current:submit { task = function() end } end,
    on_done = function(result) root_result = result end,
})
env:until_true(function() return root_result ~= nil end)
expect(not root_result.ok and not env.worker:busy(), "a slot launch failure leaked active group state")

env = environment()
local displayed = {}
root_result, group = nil, nil
assert(env.worker:startGroup {
    start = function(current)
        group = current
        for index = 1, 5 do current:emit { number = index } end
    end,
    on_progress = function(state) displayed[#displayed + 1] = state.number end,
    on_done = function(result) root_result = result end,
})
expect(#displayed == 0, "emit refreshed the root UI immediately")
env:step()
expect(#displayed == 1 and displayed[1] == 5, "a progress burst was not coalesced to its latest state")
for index = 6, 10 do group:emit { number = index } end
expect(#displayed == 1, "a second burst bypassed the root poll frequency")
env:step()
expect(#displayed == 2 and displayed[2] == 10, "coalescing lost the last progress state")
group:finish({ ok = true })
env:until_true(function() return root_result ~= nil end)

for _, root_kind in ipairs({ "group", "single" }) do
    env = environment()
    local retired, exit_ran, queue_order = false, false, {}
    local options = {
        preserve_queue = true,
        on_done = function()
            retired = true
            assert(env.worker:start {
                queue = true, preserve_queue = true,
                task = function() return "callback-job" end,
                on_done = function(result) queue_order[#queue_order + 1] = result.value end,
            })
            expect(env.next_pid == 101, "on_done launched a new writer before exit callbacks")
        end,
    }
    if root_kind == "group" then
        options.start = function(current) current:submit { task = function() return true end } end
        assert(env.worker:startGroup(options))
        env:step()
    else
        options.task = function() return true end
        assert(env.worker:start(options))
    end
    assert(env.worker:start {
        queue = true, preserve_queue = true,
        task = function() return "earlier-job" end,
        on_done = function(result) queue_order[#queue_order + 1] = result.value end,
    })
    assert(env.worker:cancelAndWait(nil, "cache_cleared", function()
        expect(env:all_reaped() and env.next_pid == 101,
            "nil-handle drain ran before reap or after a new writer started")
        exit_ran = true
    end))
    expect(not exit_ran, "nil-handle cancellation called its exit callback immediately")
    env.clock = env.clock + 6
    env:until_true(function() return retired end)
    expect(exit_ran and env.next_pid == 102, "completion barrier did not release the earlier queued job")
    env:run_child(102)
    env:until_true(function() return env.next_pid == 103 end)
    env:run_child(103)
    env:until_true(function() return not env.worker:busy() end)
    expect(table.concat(queue_order, ",") == "earlier-job,callback-job",
        "reentrant on_done overtook the existing durable queue")
end

local unavailable = Worker:new { temp_dir = temporary .. "/unavailable", scheduler = env.scheduler }
local unavailable_result
local available_ok, available_error = unavailable:startGroup {
    start = function() error("unsupported runner started a group") end,
    on_done = function(result) unavailable_result = result end,
}
expect(not available_ok and available_error == "worker_unavailable"
    and unavailable_result.error == "worker_unavailable", "unsupported runner did not preserve fallback behavior")

print(("background_group_spec: %d checks"):format(checks))
