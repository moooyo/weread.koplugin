package.path = "./?.lua;./?/init.lua;" .. package.path
local Coordinator = require("weread.lib.book_download_coordinator")
local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local function fixture(count, config)
    config = config or {}
    local h = { tasks = {}, timers = {}, requests = {}, commits = {}, order = {}, delays = {},
        peak = 0, assemblies = 0, settings_data = { cache = { download_book_images = true },
            cookies = { session = "initial" }, account = { user_vid = "fixture" } } }
    local group = { stopped = false }
    function group:cancelled() return self.stopped end
    function group:submit(options)
        if self.stopped then return nil, "cancelled" end
        local handle = { options = options }
        h.tasks[#h.tasks + 1] = handle
        return handle
    end
    function group:defer(seconds, callback)
        local handle = { seconds = seconds, callback = callback }
        h.timers[#h.timers + 1] = handle
        h.delays[#h.delays + 1] = seconds
        return handle
    end
    function group:emit(progress)
        expect(progress.completed >= (h.completed or 0), "completed progress moved backwards")
        h.completed = progress.completed
    end
    function group:finish(result)
        expect(not h.result, "group finished twice")
        h.result = result
        if not result.ok then self.stopped = true end
    end
    function group:cancel()
        self.stopped = true
    end
    local chapters = {}
    for index = 1, count do chapters[index] = { chapterUid = index, title = "Chapter " .. index } end
    local settings = { cache_dir = "/fixture/cache", data_dir = "/fixture/data",
        get = function(_self, key, default)
            if h.settings_data[key] ~= nil then return h.settings_data[key] end
            return default
        end }
    local worker = {}
    function worker.prepare(_settings, book)
        local plan = { book = book, jobs = {}, css_path = config.primed and "/fixture/style.css" or nil,
            content_format = config.primed and "epub" or nil, published = config.published }
        for index, chapter in ipairs(chapters) do
            plan.jobs[index] = { ordinal = index, chapter_uid = tostring(chapter.chapterUid), key = "key" .. index,
                cached = config.cached and config.cached[index] or false }
        end
        if config.bad_plan then plan.jobs[1].ordinal = 99 end
        return plan
    end
    function worker.acquire(private_settings, private_client, _book, chapter, options)
        local id = tostring(chapter.chapterUid)
        h.requests[id] = (h.requests[id] or 0) + 1
        h.order[#h.order + 1] = id
        expect(private_settings:get("cache").download_book_images, "active job configuration was changed")
        expect(private_client.settings:get("cookies").session == "initial", "child credentials leaked across tasks")
        private_settings:set("cookies", { session = "private" .. id })
        local failures = config.failures and config.failures[id]
        if failures and failures[h.requests[id]] then return failures[h.requests[id]] end
        return { status = "ready", key = config.bad_identity and "wrong" or options.key,
            chapter_uid = id, bundle = {}, css_path = "/fixture/style.css", content_format = "epub" }
    end
    function worker.commit(_settings, _book, chapter, ready)
        if config.commit_error then error("injected storage failure") end
        local id = tostring(chapter.chapterUid)
        h.commits[id] = (h.commits[id] or 0) + 1
        return { key = ready.key, chapter_uid = id, css_path = ready.css_path,
            content_format = "epub", resources_complete = true }
    end
    function worker.assemble(_settings, _client, _book, selected, options)
        h.assemblies = h.assemblies + 1
        h.failed = options.failed_uids
        for index, chapter in ipairs(selected) do
            expect(chapter.chapterUid == index, "assembly order changed after out-of-order acquisition")
        end
        return { path = #options.failed_uids == 0 and "/fixture/full.epub" or nil,
            failed_uids = options.failed_uids, selected_uids = {} }
    end
    h.group, h.settings = group, settings
    h.state = Coordinator.start(group, settings, {}, { book_id = "fixture", cache_dir = "/fixture/cache" },
        chapters, { worker = worker, suffix = "full", concurrency = config.concurrency or 5 })
    function h:count_tasks(kind)
        local total = 0
        for _, task in ipairs(self.tasks) do if task.options.kind == kind then total = total + 1 end end
        return total
    end
    function h:step(kind, last)
        local chosen
        for index, task in ipairs(self.tasks) do
            if not kind or task.options.kind == kind then
                chosen = index
                if not last then break end
            end
        end
        expect(chosen ~= nil, "expected a scheduled " .. tostring(kind) .. " task")
        local task = table.remove(self.tasks, chosen)
        local context = { emit = function() end, cancelled = function() return group.stopped end,
            checkCancelled = function() if group.stopped then error("cancelled") end end, sleep = function() end }
        local ok, value = pcall(task.options.task, context)
        task.options.on_done { ok = ok, value = ok and value or nil, error = not ok and tostring(value) or nil }
        expect(self:count_tasks("commit") <= 1, "more than one commit child was admitted")
        local window = self.state.acquired + self.state.ready_count + (self.state.committing and 1 or 0)
        expect(window <= (config.concurrency or 5), "uncommitted source window exceeded the configured bound")
        self.peak = math.max(self.peak, self:count_tasks("acquire"))
        return task
    end
    function h:drain()
        local iterations = 0
        while not self.result and not group.stopped do
            iterations = iterations + 1
            assert(iterations < 300, "coordinator did not finish")
            if #self.tasks > 0 then self:step()
            elseif #self.timers > 0 then table.remove(self.timers, 1).callback(group)
            else error("coordinator stalled without an active task or retry") end
        end
    end
    return h
end

local parallel = fixture(9)
parallel:step("prepare")
expect(parallel:count_tasks("acquire") == 1, "shared stylesheet was not primed serially")
parallel:step("acquire")
parallel:step("commit")
expect(parallel:count_tasks("acquire") == 5, "default five-chapter window was not opened")
parallel.settings_data.cache.download_book_images = false
parallel.settings_data.cookies.session = "parent-updated"
parallel:step("acquire", true)
parallel:drain()
expect(parallel.result.ok and parallel.result.value.path, "parallel book did not finish")
expect(parallel.peak == 5 and parallel.assemblies == 1, "wrong parallel window or assembly count")
for index = 1, 9 do
    expect(parallel.requests[tostring(index)] == 1 and parallel.commits[tostring(index)] == 1,
        "successful chapter was downloaded or committed more than once")
end
expect(parallel.settings_data.cookies.session == "parent-updated", "child overwrote live parent credentials")

local transient = { status = "failed", error = "timeout", diagnostic = { kind = "timeout", retryable = true } }
local retry = fixture(7, { primed = true, failures = { ["2"] = { transient, transient } } })
retry:drain()
expect(retry.result.ok and retry.requests["2"] == 3, "transient chapter did not receive bounded retries")
expect(#retry.delays == 2 and retry.delays[1] == 0.8 and retry.delays[2] == 1.6, "retry backoff was not exponential")
expect(retry.requests["1"] == 1 and retry.requests["7"] == 1, "retry redownloaded successful chapters")
local first_seven, last_two
for index, id in ipairs(retry.order) do if id == "7" then first_seven = index elseif id == "2" then last_two = index end end
expect(first_seven < last_two, "retry backoff occupied the acquisition slot")

local invalid_content = { status = "failed", error = "invalid chapter content" }
local exhausted = fixture(5, { primed = true, failures = { ["2"] = { invalid_content, invalid_content, invalid_content } } })
exhausted:drain()
expect(exhausted.requests["2"] == 3 and #exhausted.failed == 1 and exhausted.failed[1] == "2",
    "exhausted item was dropped or retried indefinitely")
expect(not exhausted.result.value.path, "incomplete full book was reported as complete")

local unavailable = fixture(7, { primed = true, failures = { ["2"] = { transient, transient, transient } } })
unavailable:drain()
expect(not unavailable.result.ok and unavailable.requests["2"] == 3 and unavailable.assemblies == 0,
    "persistent network failure kept traversing the book after exhausting retries")
expect(unavailable.result.pause and unavailable.result.error_kind == "timeout"
    and unavailable.result.error == transient.error, "paused coordinator lost its kind or original diagnostic error")
local http_failure = { status = "failed", error = "/fixture/content.lua:1635: source failed: HTTP 503",
    diagnostic = { status = 503, kind = "http_status", retryable = true } }
local http_paused = fixture(5, { primed = true, failures = { ["2"] = { http_failure, http_failure, http_failure } } })
http_paused:drain()
expect(http_paused.result.pause and http_paused.result.http_status == 503
    and http_paused.result.error_kind == "http_status" and http_paused.result.error == http_failure.error,
    "HTTP pause metadata or original error was dropped before reaching the downloader")

local permanent = fixture(5, { primed = true, failures = { ["2"] = {
    { status = "failed", error = "not found", diagnostic = { status = 404, retryable = false } },
} } })
permanent:drain()
expect(permanent.requests["2"] == 1 and permanent.failed[1] == "2", "permanent failure was retried")

for _, diagnostic in ipairs({ { status = 429 }, { status = 401 }, { api_code = -10102 } }) do
    local paused = fixture(9, { primed = true, failures = { ["1"] = {
        { status = "failed", error = "upstream rejection", diagnostic = diagnostic },
    } } })
    paused:step("prepare")
    paused:step("acquire")
    expect(not paused.result.ok and paused.group.stopped and paused.assemblies == 0,
        "upstream rejection did not pause the whole group")
    expect(paused.requests["1"] == 1 and paused.requests["2"] == nil and #paused.delays == 0,
        "rejected group kept acquiring or scheduled a retry")
    expect(paused.result.pause and paused.result.http_status == diagnostic.status
        and paused.result.api_code == diagnostic.api_code, "upstream pause metadata was lost")
end

local storage = fixture(5, { commit_error = true })
storage:drain()
expect(not storage.result.ok and storage.requests["1"] == 1 and storage.assemblies == 0,
    "commit error caused another download or publication")
local wrong = fixture(5, { bad_identity = true })
wrong:drain()
expect(not wrong.result.ok and next(wrong.commits) == nil, "wrong chapter result was committed")
local invalid_plan = fixture(5, { bad_plan = true })
invalid_plan:drain()
expect(not invalid_plan.result.ok and next(invalid_plan.requests) == nil, "invalid plan started acquisition")

local cancelled = fixture(2, { failures = { ["1"] = { transient } } })
cancelled:step("prepare")
cancelled:step("acquire")
expect(#cancelled.timers == 1, "retry timer was not scheduled")
cancelled.group:cancel()
local count_before = #cancelled.tasks
cancelled.timers[1].callback(cancelled.group)
expect(#cancelled.tasks == count_before and cancelled.assemblies == 0,
    "a cancelled retry timer restarted acquisition")

local replay = fixture(3, { published = { path = "/fixture/ready.epub" } })
replay:drain()
expect(replay.result.value.path == "/fixture/ready.epub" and next(replay.requests) == nil
    and replay.assemblies == 0, "published output was downloaded or assembled again")
local cached = fixture(3, { cached = { true, true, true } })
cached:drain()
expect(cached.assemblies == 1 and next(cached.requests) == nil, "committed sources were not reused")
local serial = fixture(4, { concurrency = 1, primed = true })
serial:drain()
expect(serial.peak == 1 and serial.result.ok, "configured serial mode did not limit acquisition")

print("book_download_coordinator_spec: " .. checks .. " checks passed")
