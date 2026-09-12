-- Unit tests for weread/lib/progress_sync.lua.
-- Run from the repo root with:
--   lua spec/progress_sync_spec.lua

package.path = "./?.lua;" .. package.path
local ProgressSync = require("weread.lib.progress_sync")

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

-- Mirrors PULL_RETRY_DELAY_SECONDS in weread/lib/progress_sync.lua.
local PULL_RETRY_DELAY_SECONDS = 15

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    { chapterUid = 33, chapterIdx = 3, wordCount = 600 },
}

local function fixture(remote, options)
    options = options or {}
    local document = {
        file = "/cache/book/full.epub",
        page = 25,
        getCurrentPage = function(self) return self.page end,
        getPageCount = function() return 100 end,
    }
    local book = {
        book_id = "book",
        title = "Book",
        summary = "Book",
        cached_file = document.file,
        cached_chapters = {
            ["11"] = document.file,
            ["22"] = document.file,
            ["33"] = document.file,
        },
    }
    local values = {
        sync = {
            pull_on_open = true,
            upload_on_close = true,
            ask_on_conflict = true,
        },
        books = { book = book },
    }
    local settings = {
        get = function(_self, key, default)
            return values[key] or default
        end,
        set = function(_self, key, value)
            values[key] = value
        end,
        flush = function() end,
        is_api_configured = function() return true end,
        is_cookie_configured = function() return true end,
    }
    local queue = {}
    local scheduler = {
        scheduleIn = function(_self, delay, callback)
            queue[#queue + 1] = { delay = delay, callback = callback }
        end,
    }
    local choices = {}
    local uploads = {}
    local pulls = {}
    local jumps = {}
    local notifications = {}
    local client = {
        get_progress = function()
            pulls[#pulls + 1] = "gateway"
            return { book = remote }
        end,
        get_web_progress = function()
            pulls[#pulls + 1] = "web"
            return remote
        end,
    }
    local sync = ProgressSync:new{
        settings = settings,
        client = client,
        scheduler = scheduler,
        get_document = function() return document end,
        detect_book = function() return "book" end,
        get_book = function() return book end,
        get_chapters = options.get_chapters or function() return chapters end,
        refresh_catalog = options.refresh_catalog,
        get_file_context = function()
            return nil, nil, true
        end,
        run_online = options.run_online or function(_kind, callback)
            callback()
            return true
        end,
        upload_position = function(_book_id, position, elapsed)
            uploads[#uploads + 1] = position
            eq(elapsed, 0, "progress upload has zero reading time")
            return true, { accepted = true }
        end,
        goto_fraction = function(fraction)
            jumps[#jumps + 1] = fraction
            document.page = math.floor(fraction * 100 + 0.5)
            return true
        end,
        open_chapter = function() return true end,
        on_choice = function(context)
            choices[#choices + 1] = context
        end,
        notify = function(code, data)
            notifications[#notifications + 1] = { code = code, data = data }
        end,
        is_online = options.is_online,
        is_downloading = options.is_downloading,
        now = options.now,
    }
    local function step()
        local entry = table.remove(queue, 1)
        if not entry then return false end
        entry.callback()
        return true
    end
    local function drain()
        local count = 0
        while #queue > 0 do
            count = count + 1
            assert(count < 20, "scheduler did not quiesce")
            step()
        end
    end
    return {
        sync = sync,
        document = document,
        values = values,
        choices = choices,
        uploads = uploads,
        pulls = pulls,
        jumps = jumps,
        notifications = notifications,
        queue = queue,
        step = step,
        drain = drain,
    }
end

test("matching open progress verifies the reporting gate", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "session verified")
    eq(#f.choices, 0, "no conflict dialog")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(applies, true, "provider applies")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
    eq(position.chapter_offset, 150, "live offset")
end)

test("nearby progress within two percent is treated as aligned", function()
    local f = fixture({
        bookId = "book",
        progress = 26.9,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 169,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "nearby position verifies")
    eq(#f.choices, 0, "nearby position does not prompt")
end)

test("unresolved conflict blocks reports and local choice uploads", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "conflict dialog requested")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(position, nil, "position withheld")
    eq(reason, "progress_unverified", "gate reason")
    eq(applies, true, "provider applies")
    f.choices[1].keep_local()
    eq(f.sync:status().verified, true, "local choice verifies")
    eq(#f.uploads, 1, "local choice uploads immediately")
    eq(f.uploads[1].chapter_offset, 150, "uploaded immutable position")
end)

test("page change uploads once on close", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 50
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "page change marks dirty")
    f.sync:on_close_document()
    eq(#f.uploads, 1, "close uploads once")
    eq(f.uploads[1].percent, 50, "close uploads current percent")
    eq(f.uploads[1].chapter_uid, 33, "close uploads current chapter")
    eq(f.values.books.book.pending_upload_position, nil,
        "successful upload clears pending snapshot")
end)

test("remote choice jumps and verifies before reporting", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    f.drain()
    eq(#f.jumps, 1, "one jump")
    eq(f.jumps[1], 0.5, "jump fraction")
    eq(f.sync:status().verified, true, "remote choice verifies")
    local position = f.sync:position_for_report("book")
    eq(position.percent, 50, "report sees jumped position")
end)

test("busy read report is retried with the immutable snapshot", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    local attempts = 0
    local uploaded
    f.sync.upload_position = function(_book_id, position)
        attempts = attempts + 1
        if attempts == 1 then
            return false, { error = "busy", error_kind = "busy" }
        end
        uploaded = position
        return true, { accepted = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].keep_local()
    -- Mutating the live page must not change the already captured retry.
    f.document.page = 75
    f.drain()
    eq(attempts, 2, "busy upload retried")
    eq(uploaded.percent, 25, "retry uses immutable position")
    eq(f.values.books.book.pending_upload_position, nil,
        "retry success clears pending snapshot")
end)

test("suspend captures movement even without a page event", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    eq(#f.uploads, 1, "suspend uploads captured movement")
    eq(f.uploads[1].percent, 40, "suspend uses current page")
end)

test("single chapter cloud choice waits for target chapter then jumps", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    local current_chapter = chapters[1]
    local requested_chapter
    f.sync.get_file_context = function()
        return 1, current_chapter, false
    end
    f.sync.open_chapter = function(_book, chapter)
        requested_chapter = chapter
        return true
    end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "chapter conflict requested")
    f.choices[1].use_remote()
    eq(requested_chapter.chapterUid, 22, "target chapter requested")
    eq(f.sync:status().verified, false, "reporting remains gated")
    eq(f.sync:status().state, "switching_chapter", "waiting for open")

    -- Simulate the downloader opening the requested single-chapter EPUB.
    current_chapter = chapters[2]
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "target chapter verifies")
    eq(f.jumps[#f.jumps], 0.5, "target chapter offset applied")
end)

test("cancelling target chapter download clears the pending jump", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync.get_file_context = function()
        return 1, chapters[1], false
    end
    f.sync.open_chapter = function() return true end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    eq(f.sync:cancel_pending_jump("cancelled"), true, "pending cancelled")
    eq(f.sync:status().state, "unverified", "returns to safe state")
    eq(f.sync:status().verified, false, "reporting stays gated")
end)

test("automatic hooks stay disabled when flags are absent", function()
    local f = fixture({
        bookId = "book",
        progress = 75,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 300,
        updateTime = 10,
    })
    f.values.sync = {}
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().state, "unverified", "open does not pull by default")
    eq(#f.choices, 0, "open does not prompt by default")

    f.sync.verified = true
    f.sync.dirty = true
    f.sync:on_close_document()
    eq(#f.uploads, 0, "close does not upload by default")
end)

test("manual sync refreshes a missing catalog inside the online task", function()
    local available_chapters
    local refresh_count = 0
    local online_count = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        get_chapters = function() return available_chapters end,
        refresh_catalog = function(book_id)
            eq(book_id, "book", "refresh receives current book")
            refresh_count = refresh_count + 1
            available_chapters = chapters
            return chapters
        end,
        run_online = function(_kind, callback)
            online_count = online_count + 1
            callback()
            return true
        end,
    })
    eq(f.sync:sync_now(), true, "manual sync starts")
    eq(refresh_count, 1, "catalog refreshed once")
    eq(online_count, 1, "catalog and progress share one online task")
    eq(f.sync:status().verified, true, "refreshed catalog completes sync")
    eq(#f.notifications, 1, "aligned manual sync notifies once")
    eq(f.notifications[1].code, "already_synced", "sync result notified")
end)

test("automatic open never refreshes a missing catalog", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(refresh_count, 0, "automatic path stays offline")
    eq(f.sync:status().state, "unsafe", "missing catalog degrades safely")
end)

test("offline manual catalog refresh reports offline instead of raw reason", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline sync does not start")
    eq(refresh_count, 0, "offline path does not refresh")
    eq(#f.notifications, 1, "offline failure notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("offline automatic pull schedules a delayed retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    -- Wi-Fi is usually still settling when the open delay expires.
    f.step()
    eq(f.sync:status().state, "offline", "automatic pull records offline")
    eq(#f.queue, 1, "offline automatic pull queues one retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry waits for the link")
    eq(#f.notifications, 0, "automatic retry stays silent")
end)

test("automatic pull retries stop at the attempt limit", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "first retry queued")
    f.step()
    eq(#f.queue, 1, "second retry queued")
    f.step()
    eq(#f.queue, 1, "third retry queued")
    f.step()
    eq(#f.queue, 0, "retries stop at the limit")
    eq(f.sync:status().verified, false, "exhausted retries stay gated")
end)

test("offline manual sync never schedules a retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline manual sync does not start")
    eq(#f.queue, 0, "manual path leaves the queue empty")
    eq(#f.notifications, 1, "manual offline notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("retries queued for a closed book never pull again", function()
    local online_checks = 0
    local f = fixture({}, {
        is_online = function()
            online_checks = online_checks + 1
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "retry queued for the open book")
    f.sync:on_close_document()
    f.step()
    eq(online_checks, 1, "stale retry never reaches the offline check")
    eq(#f.queue, 0, "stale retry does not queue another attempt")
end)

test("a queued retry verifies once the link comes back", function()
    local online = false
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        is_online = function() return online end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().verified, false, "offline open leaves the gate closed")
    online = true
    f.drain()
    eq(f.sync:status().verified, true, "retry verifies the reporting gate")
    eq(#f.choices, 0, "no conflict dialog")
    eq(#f.notifications, 0, "automatic retry stays silent")
    local position, reason = f.sync:position_for_report("book")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
end)

test("automatic pull retries when the online task cannot start", function()
    local run_options
    local f = fixture({}, {
        is_online = function() return true end,
        run_online = function(_kind, _callback, options)
            run_options = options
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().state, "offline", "failed online task records offline")
    eq(#f.queue, 1, "failed automatic online task queues one retry")
    eq(f.queue[1].delay, PULL_RETRY_DELAY_SECONDS, "retry remains delayed")
    eq(run_options.silent_offline, true, "automatic preflight stays silent")
    eq(#f.notifications, 0, "automatic start failure does not notify")
end)

test("queued automatic retry does not duplicate a manual conflict", function()
    local online = false
    local f = fixture({
        bookId = "book",
        progress = 80,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 500,
        updateTime = 10,
    }, {
        is_online = function() return online end,
    })
    f.sync:on_reader_ready()
    f.step()
    online = true
    f.sync:sync_now()
    eq(#f.choices, 1, "manual sync opens one conflict")
    f.step()
    eq(#f.choices, 1, "stale automatic retry does not reopen conflict")
    eq(#f.queue, 0, "stale retry chain ends")
end)

test("a fresh automatic pull replaces an older retry chain", function()
    local now = 0
    local f = fixture({}, {
        is_online = function() return false end,
        now = function() return now end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "open queues the first retry chain")
    f.sync:on_suspend()
    now = 5 * 60
    f.sync:on_resume()
    eq(#f.queue, 2, "resume queues its replacement chain")
    f.step()
    eq(#f.queue, 1, "stale chain does not schedule another retry")
    f.step()
    eq(#f.queue, 1, "replacement chain remains active")
end)

local function aligned_fixture(options)
    return fixture({
        bookId = "book", progress = 25, chapterUid = 22,
        chapterIdx = 2, chapterOffset = 150, updateTime = 10,
    }, options)
end

test("download waits preserve the complete automatic pull retry budget", function()
    local downloading, online_checks = true, 0
    local f = aligned_fixture({
        is_downloading = function() return downloading end,
        is_online = function()
            online_checks = online_checks + 1
            return false
        end,
    })
    f.sync:on_reader_ready()
    for _ = 1, 6 do eq(f.step(), true, "download wait remains scheduled") end
    eq(online_checks, 0, "download waits do not attempt an online check")
    eq(#f.pulls, 0, "download waits do not fetch remote progress")
    eq(f.sync:status().pulling, false, "download wait does not hold the pull lock")
    eq(#f.notifications, 0, "automatic download waits remain silent")
    downloading = false
    f.drain()
    eq(online_checks, 4, "initial pull and all three retries remain available")
    eq(#f.queue, 0, "offline attempts stop after the normal retry budget")
end)

test("resume pull waits for download completion", function()
    local downloading, now = false, 0
    local f = aligned_fixture({
        is_downloading = function() return downloading end,
        now = function() return now end,
    })
    f.sync:on_reader_ready()
    f.drain()
    local initial_pulls = #f.pulls
    f.sync:on_suspend()
    now, downloading = 5 * 60, true
    f.sync:on_resume()
    for _ = 1, 5 do eq(f.step(), true, "resume remains deferred while downloading") end
    eq(#f.pulls, initial_pulls, "resume does not pull during the download")
    eq(f.sync:status().pulling, false, "deferred resume releases the pull lock")
    downloading = false
    f.drain()
    eq(#f.pulls, initial_pulls + 2, "resume fetches each remote source once")
    eq(f.sync:status().verified, true, "resume verifies after the download")
end)

test("automatic pull checks downloading again inside the online callback", function()
    local downloading, callbacks = false, {}
    local f = aligned_fixture({
        is_downloading = function() return downloading end,
        run_online = function(_kind, callback)
            callbacks[#callbacks + 1] = callback
            return true
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#callbacks, 1, "automatic pull reaches the online scheduler")
    downloading = true
    callbacks[1]()
    eq(#f.pulls, 0, "late download start blocks both remote sources")
    eq(f.sync:status().pulling, false, "late download start releases the pull lock")
    eq(#f.queue, 1, "late download start queues one deferred pull")
    downloading = false
    f.sync.run_online = function(_kind, callback) callback(); return true end
    f.drain()
    eq(#f.pulls, 2, "deferred callback resumes one pull")
    eq(f.sync:status().verified, true, "resumed callback verifies the session")
end)

test("close preserves its snapshot and upload budget throughout a download", function()
    local downloading = false
    local f = aligned_fixture({ is_downloading = function() return downloading end })
    f.sync:on_reader_ready()
    f.drain()
    downloading = true
    f.document.page = 50
    f.sync:on_page_update()
    local generation = f.sync.generation
    f.sync:on_close_document()
    eq(f.sync.generation, generation + 1, "close immediately invalidates old pull work")
    eq(#f.uploads, 0, "close does not upload during the download")
    eq(f.sync:status().uploading, false, "download wait does not hold the upload lock")
    eq(f.values.books.book.pending_upload_position.percent, 50, "close persists its snapshot")
    for _ = 1, 12 do eq(f.step(), true, "upload wait outlives the network retry budget") end
    eq(#f.uploads, 0, "long download wait still makes no upload")
    eq(f.sync:status().uploading, false, "long download wait leaves newer snapshots possible")
    local attempts, uploaded = 0
    f.sync.upload_position = function(_book_id, position)
        attempts = attempts + 1
        if attempts < 10 then return false, { error = "busy", error_kind = "busy" } end
        uploaded = position
        return true, { accepted = true }
    end
    downloading = false
    f.drain()
    eq(attempts, 10, "download waits do not consume any upload attempt")
    eq(uploaded and uploaded.percent, 50, "closed document uploads its immutable snapshot")
    eq(f.values.books.book.pending_upload_position, nil, "successful deferred upload clears pending")
    eq(f.sync:status().state == "uploading", false, "closed-session completion clears the uploading state")
end)

test("automatic upload checks downloading again inside the online callback", function()
    local downloading, callbacks = false, {}
    local f = aligned_fixture({ is_downloading = function() return downloading end })
    f.sync:on_reader_ready()
    f.drain()
    local generation = f.sync.generation
    f.sync.run_online = function(_kind, callback)
        callbacks[#callbacks + 1] = callback
        return true
    end
    f.document.page = 50
    f.sync:on_close_document()
    eq(f.sync.generation, generation + 1, "close invalidates old pulls before returning")
    eq(#callbacks, 1, "close schedules one online callback")
    downloading = true
    callbacks[1]()
    eq(#f.uploads, 0, "late download start prevents the upload")
    eq(f.sync:status().uploading, false, "deferred callback releases the upload lock")
    eq(f.sync:status().state == "uploading", false, "late download start clears the uploading state")
    eq(f.values.books.book.pending_upload_position.percent, 50, "deferred callback keeps its snapshot")
    downloading = false
    f.sync.run_online = function(_kind, callback) callback(); return true end
    f.drain()
    eq(#f.uploads, 1, "deferred upload resumes exactly once")
    eq(f.uploads[1] and f.uploads[1].percent, 50, "deferred callback uses the captured position")
end)

test("a newer same-book snapshot replaces an older deferred upload", function()
    local downloading = false
    local f = aligned_fixture({
        is_downloading = function() return downloading end,
        now = function() return 100 end,
    })
    f.sync:on_reader_ready()
    f.drain()
    downloading = true
    f.document.page = 40
    f.sync:on_suspend()
    eq(f.values.books.book.pending_upload_position.percent, 40, "suspend captures the first snapshot")
    eq(f.sync:status().uploading, false, "first deferred snapshot leaves upload available")
    f.document.page = 60
    f.sync:on_page_update()
    f.sync:on_close_document()
    eq(f.values.books.book.pending_upload_position.percent, 60, "close replaces the older snapshot")
    downloading = false
    f.drain()
    eq(#f.uploads, 1, "superseded deferred snapshot never uploads")
    eq(f.uploads[1] and f.uploads[1].percent, 60, "latest snapshot wins even at the same timestamp")
    eq(f.values.books.book.pending_upload_position, nil, "latest accepted snapshot clears pending")
end)

test("a closed-session upload cannot clear movement in a reopened document", function()
    local callback
    local f = aligned_fixture()
    f.sync:on_reader_ready()
    f.drain()
    f.sync.run_online = function(kind, action)
        if kind == "progress_upload" then callback = action else action() end
        return true
    end
    f.document.page = 40
    f.sync:on_close_document()
    f.document.page = 25
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 60
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "reopened document has fresh movement")
    callback()
    eq(#f.uploads, 1, "closing snapshot can still finish after reopening")
    eq(f.uploads[1] and f.uploads[1].percent, 40, "old completion uploads only its own snapshot")
    eq(f.sync:status().dirty, true, "old completion does not clear new movement")
    eq(f.sync:status().local_position.percent, 60, "old completion does not replace the live position")
end)

local function set_fake_credentials(values)
    values.account = { user_vid = "offline-user-a", login_time = 100 }
    values.cookies = { wr_vid = "offline-user-a", wr_skey = "offline-cookie-a" }
    values.api_key = "offline-api-a"
end

for _, field in ipairs({ "account", "login_time", "cookies", "api_key" }) do
    test("changed " .. field .. " revokes a deferred automatic upload", function()
        local downloading = false
        local f = aligned_fixture({ is_downloading = function() return downloading end })
        set_fake_credentials(f.values)
        f.sync:on_reader_ready()
        f.drain()
        downloading = true
        f.document.page = 40
        f.sync:on_suspend()
        if field == "account" then
            f.values.account.user_vid = "offline-user-b"
        elseif field == "login_time" then
            f.values.account.login_time = 101
        elseif field == "cookies" then
            f.values.cookies.wr_vid = "offline-user-b"
        else
            f.values.api_key = "offline-api-b"
        end
        downloading = false
        f.drain()
        eq(#f.uploads, 0, "credentials changed before deferred upload reached the network")
        eq(f.sync:status().uploading, false, "revoked upload releases its state")
        eq(f.values.books.book.pending_upload_position, nil, "revoked identity clears its old pending snapshot")
    end)
end

test("credential changes also revoke an already scheduled online upload", function()
    local callback
    local f = aligned_fixture()
    set_fake_credentials(f.values)
    f.sync:on_reader_ready()
    f.drain()
    f.sync.run_online = function(_kind, action) callback = action; return true end
    f.document.page = 40
    f.sync:on_close_document()
    f.values.api_key = "offline-api-b"
    callback()
    eq(#f.uploads, 0, "online callback rejects the old account identity")
    eq(f.sync:status().uploading, false, "revoked callback releases uploading")
    eq(f.sync:status().state == "uploading", false, "revoked callback clears the uploading state")
    eq(f.values.books.book.pending_upload_position, nil, "revoked callback clears the old pending snapshot")
end)

test("equivalent credential tables preserve a deferred automatic upload", function()
    local downloading = false
    local f = aligned_fixture({ is_downloading = function() return downloading end })
    set_fake_credentials(f.values)
    f.sync:on_reader_ready()
    f.drain()
    downloading = true
    f.document.page = 40
    f.sync:on_suspend()
    set_fake_credentials(f.values)
    downloading = false
    f.drain()
    eq(#f.uploads, 1, "equivalent account values do not revoke an upload")
    eq(f.uploads[1] and f.uploads[1].percent, 40, "unchanged identity retains the original snapshot")
end)

test("same-account session credential rotation preserves a deferred upload", function()
    local downloading = false
    local f = aligned_fixture({ is_downloading = function() return downloading end })
    set_fake_credentials(f.values)
    f.values.wr_ticket, f.values.wr_wrpa = "offline-ticket-a", "offline-wrpa-a"
    f.sync:on_reader_ready()
    f.drain()
    downloading = true
    f.document.page = 40
    f.sync:on_suspend()
    f.values.cookies.wr_skey = "offline-cookie-rotated"
    f.values.wr_ticket, f.values.wr_wrpa = "offline-ticket-rotated", "offline-wrpa-rotated"
    downloading = false
    f.drain()
    eq(#f.uploads, 1, "session rotation does not revoke a stable account identity")
    eq(f.uploads[1] and f.uploads[1].percent, 40, "rotated session uploads the original snapshot")
    eq(f.values.books.book.pending_upload_position, nil, "rotated session success clears pending")
end)

test("explicit local choice supersedes an older deferred automatic snapshot", function()
    local downloading = false
    local f = aligned_fixture({
        is_downloading = function() return downloading end,
        now = function() return 100 end,
    })
    f.sync:on_reader_ready()
    f.drain()
    downloading = true
    f.document.page = 40
    f.sync:on_suspend()
    f.document.page = 60
    f.sync:on_page_update()
    f.sync:sync_now()
    eq(#f.choices, 1, "manual conflict can supersede a deferred automatic snapshot")
    f.choices[1].keep_local()
    eq(#f.uploads, 1, "explicit local choice uploads while the download continues")
    eq(f.uploads[1] and f.uploads[1].percent, 60, "explicit choice uploads the newer snapshot")
    downloading = false
    f.drain()
    eq(#f.uploads, 1, "old automatic callback cannot overwrite the explicit choice")
    eq(f.values.books.book.last_uploaded_position.percent, 60, "explicit choice remains the last upload")
    eq(f.values.books.book.pending_upload_position, nil, "superseded automatic snapshot stays cleared")
end)

test("manual sync and explicit local choice remain available during downloads", function()
    local f = fixture({
        bookId = "book", progress = 50, chapterUid = 33,
        chapterIdx = 3, chapterOffset = 100, updateTime = 10,
    }, { is_downloading = function() return true end })
    eq(f.sync:sync_now(), true, "manual sync bypasses the download gate")
    eq(#f.pulls, 2, "manual sync fetches both remote sources")
    eq(#f.choices, 1, "manual sync can present its conflict")
    f.choices[1].keep_local()
    eq(#f.uploads, 1, "explicit local choice bypasses the download gate")
    eq(f.uploads[1] and f.uploads[1].percent, 25, "explicit choice uploads the selected local position")
    eq(#f.queue, 0, "explicit operations do not leave automatic download waits")
end)

print(string.format(
    "progress_sync_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
