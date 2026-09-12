-- A UI-owned task group. Each slot forks directly from the UI process through
-- an independent BackgroundWorker; the group itself never enters a subprocess.
local Group = {}
Group.__index = Group

local function bounded(value, default, maximum)
    value = tonumber(value)
    if not value or value ~= value or value < 0 or value > maximum then return default end
    return value
end

function Group:new(options)
    return setmetatable({
        owner = options.owner, request = options.request,
        concurrency = options.concurrency, slot_factory = options.slot_factory,
        is_parent = options.is_parent,
        additional_slot_memory_kb = bounded(options.additional_slot_memory_kb, 16 * 1024, 1024 * 1024),
        memory_wait_seconds = bounded(options.memory_wait_seconds, 10, 60),
        queue = {}, slots = {}, deferred = {}, active = 0, sequence = 0,
    }, self)
end

function Group:_parent()
    assert(self.is_parent(), "group methods must run in the UI parent process")
end

function Group:_touch()
    local job = self.owner.job
    if job and job.group == self then job.last_progress_at = self.owner.now() end
end

function Group:_call(callback, ...)
    if type(callback) ~= "function" then return true end
    local args = { n = select("#", ...), ... }
    local ok, err = xpcall(function() return callback(unpack(args, 1, args.n)) end, debug.traceback)
    if not ok then self:_fail(err) end
    return ok
end

function Group:_notify(handle, result)
    if handle.completed then return end
    handle.completed = true
    handle.result = result
    self:_call(handle.options.on_done, result)
end

function Group:_clearDeferred()
    local deferred = self.deferred
    self.deferred = {}
    for handle in pairs(deferred) do
        handle.cancelled = true
        if type(self.owner.scheduler.unschedule) == "function" then
            pcall(self.owner.scheduler.unschedule, self.owner.scheduler, handle.callback)
        end
    end
end

function Group:_close(result, cancel_active)
    if self.finished then return false end
    if self.result then
        -- Keep the original failure/cancellation when teardown callbacks fail.
        if not self.result.ok then return false end
        if result.ok then return false end
    end
    self.result = result
    self.result.task_token = self.request.token
    self.pending_progress = nil
    self:_clearDeferred()
    local pending = self.queue
    self.queue = {}
    for _, handle in ipairs(pending) do
        self:_notify(handle, { ok = false, cancelled = true,
            error = result.error or "group_finished" })
    end
    if cancel_active then
        for _, slot in ipairs(self.slots) do
            if slot.handle then slot.worker:cancel(slot.worker_handle, result.error or "group_finished") end
        end
    end
    self.owner:_schedule()
    return true
end

function Group:_fail(err)
    return self:_close({ ok = false, error = tostring(err) }, true)
end

function Group:cancelled()
    self:_parent()
    return self.cancel_requested == true or self.result ~= nil and self.result.ok == false
end

function Group:cancel(reason)
    self:_parent()
    if self.finished then return false end
    self.cancel_requested = true
    return self:_close({ ok = false, cancelled = true, error = reason or "cancelled" }, true)
end

-- Failure stops all admission immediately. Both success and failure wait for
-- every launched child to be reaped before the owner's on_done can run.
function Group:finish(result)
    self:_parent()
    assert(type(result) == "table" and type(result.ok) == "boolean", "group result requires ok")
    local outcome = {}
    for key, value in pairs(result) do outcome[key] = value end
    return self:_close(outcome, not outcome.ok)
end

function Group:emit(state)
    self:_parent()
    if self.finished or self.result then return false end
    local progress = {}
    for key, value in pairs(state or {}) do progress[key] = value end
    progress.task_token = self.request.token
    progress.updated_at = self.owner.now()
    self:_touch()
    self.pending_progress = progress
    self.owner:_schedule()
    return true
end

function Group:submit(options)
    self:_parent()
    assert(type(options) == "table" and type(options.task) == "function", "group task required")
    if self.result or self.finished then return nil, "group_finished" end
    self.sequence = self.sequence + 1
    local handle = { token = self.request.token .. "-" .. tostring(self.sequence), options = options }
    self.queue[#self.queue + 1] = handle
    self.owner:_schedule()
    return handle
end

function Group:defer(seconds, callback)
    self:_parent()
    assert(type(callback) == "function", "deferred group callback required")
    if self.result or self.finished then return nil, "group_finished" end
    seconds = tonumber(seconds) or 0
    assert(seconds >= 0 and seconds < math.huge, "invalid group delay")
    local handle = {}
    handle.callback = function()
        if not self.deferred[handle] or self.result or self.finished then return end
        self.deferred[handle] = nil
        self:_call(callback, self)
        self.owner:_schedule()
    end
    self.deferred[handle] = true
    local ok, err = pcall(self.owner.scheduler.scheduleIn, self.owner.scheduler, seconds, handle.callback)
    if not ok then self.deferred[handle] = nil; self:_fail(err) end
    return handle
end

function Group:_childDone(slot, handle, result)
    if slot.handle ~= handle then return end
    slot.handle, slot.worker_handle = nil, nil
    self.active = self.active - 1
    self:_touch()
    if self.result and not self.result.ok then
        result = { ok = false, cancelled = true, error = self.result.error or "group_finished" }
    end
    self:_notify(handle, result)
    self.owner:_schedule()
end

function Group:_launch(slot, handle)
    slot.handle = handle
    self.active = self.active + 1
    handle.started = true
    self:_touch()
    local called, ok, worker_handle = pcall(slot.worker.start, slot.worker, {
        task = handle.options.task,
        timeout = handle.options.timeout or self.request.options.timeout or self.owner.timeout,
        on_launch = function(pid, available_kb)
            handle.pid = pid
            self:_call(handle.options.on_launch, pid, available_kb)
        end,
        on_progress = function(state)
            if slot.handle ~= handle then return end
            self:_touch()
            if not self.result then self:_call(handle.options.on_progress, state) end
        end,
        on_done = function(result) self:_childDone(slot, handle, result) end,
    })
    if not called then
        local err = ok
        if not slot.worker:busy() then
            self:_childDone(slot, handle, { ok = false, error = tostring(err) })
        end
        self:_fail(err)
        return
    end
    if slot.handle == handle then slot.worker_handle = worker_handle end
    if not ok then
        if not handle.completed then
            self:_childDone(slot, handle, { ok = false, error = worker_handle or "worker_launch_failed" })
        end
        self:_fail(worker_handle or "worker_launch_failed")
    end
end

function Group:_pump()
    while not self.result and #self.queue > 0 and self.active < self.concurrency do
        local free_kb = self.owner:availableMemoryKB()
        -- This is a soft admission margin, not a reservation of child memory.
        local minimum = self.owner.min_available_kb + self.active * self.additional_slot_memory_kb
        if free_kb and free_kb < minimum then
            if self.active == 0 then
                self.memory_wait_started = self.memory_wait_started or self.owner.now()
                if self.owner.now() - self.memory_wait_started >= self.memory_wait_seconds then
                    self:_close({ ok = false, error = "low_memory", available_kb = free_kb }, true)
                end
            end
            return
        end
        self.memory_wait_started = nil
        local slot
        for _, candidate in ipairs(self.slots) do
            if not candidate.handle then slot = candidate; break end
        end
        if not slot then
            slot = { worker = self.slot_factory(#self.slots + 1) }
            self.slots[#self.slots + 1] = slot
        end
        self:_launch(slot, table.remove(self.queue, 1))
    end
end

function Group:poll()
    self:_parent()
    local progress = self.pending_progress
    self.pending_progress = nil
    if progress and not self.result then self:_call(self.request.options.on_progress, progress) end
    if not self.result then
        local ok, err = xpcall(function() self:_pump() end, debug.traceback)
        if not ok then self:_fail(err) end
    end
    return self.result ~= nil and self.active == 0, self.result
end

function Group:cleanup()
    self.finished = true
    self:_clearDeferred()
    local lfs = require("libs/libkoreader-lfs")
    if type(lfs.rmdir) == "function" then
        for _, slot in ipairs(self.slots) do pcall(lfs.rmdir, slot.worker.temp_dir) end
        if self.temp_dir then pcall(lfs.rmdir, self.temp_dir) end
    end
end

return Group
