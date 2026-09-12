-- Focused tests for ReadReport's progress gate and enter/report sequencing.
-- Run from the repo root with:
--   lua spec/read_report_progress_spec.lua

package.path = "./?.lua;" .. package.path

local cached_catalog
local saved_catalog
package.preload["weread.lib.content"] = function()
    return {
        load_catalog_cache = function(_client, _settings, book)
            if cached_catalog then book.chapters = cached_catalog end
            return cached_catalog
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_catalog = chapters
            return true
        end,
    }
end

package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        web_app_id = function() return "app" end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        make_enter_read_payload = function(options)
            return {
                kind = "enter",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
            }
        end,
        make_read_payload = function(options)
            return {
                kind = "report",
                chapter_uid = options.chapter_uid,
                chapter_offset = options.chapter_offset,
                progress = options.progress,
                elapsed_seconds = options.elapsed_seconds,
            }
        end,
        is_success_response = function(value)
            return type(value) == "table" and value.succ == 1
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

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

local function fixture(provider, options)
    options = options or {}
    local records = {}
    local scheduled = {}
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "auto",
                    interval_seconds = 30,
                }
            end
            if key == "books" then
                return { book = { title = "Book" } }
            end
            return {}
        end,
        is_cookie_configured = function() return true end,
    }
    local client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function() end,
        },
        get_document = function() return { file = "/book.epub" } end,
        detect_book = function() return "book" end,
        position_provider = provider,
        is_online = options.is_online or function() return true end,
        is_downloading = options.is_downloading,
        subprocess = false,
        now = function() return 100 end,
    }
    return report, records, scheduled
end

test("unverified position blocks reading-time reporting", function()
    local report = fixture(function()
        return nil, "progress_unverified", true
    end)
    local proceed = report:_precheck()
    eq(proceed, false, "precheck blocked")
    eq(report:status().state, "waiting_for_progress", "waiting state")
end)

test("verified live position passes the reporting gate", function()
    local live = { chapter_uid = 22, chapter_offset = 150, percent = 25 }
    local report = fixture(function()
        return live, nil, true
    end)
    local proceed, book_id, position = report:_precheck()
    eq(proceed, true, "precheck passed")
    eq(book_id, "book", "target book")
    eq(position, live, "live position forwarded")
end)

test("manual download defers scheduled reports without consuming failures", function()
    local downloading, online_checks, position_checks, spawned = true, 0, 0, 0
    local report, _, scheduled = fixture(function()
        position_checks = position_checks + 1
        return { chapter_uid = 22 }, nil, true
    end, {
        is_downloading = function() return downloading end,
        is_online = function() online_checks = online_checks + 1; return true end,
    })
    report._start_job = function() spawned = spawned + 1; return true end
    report:start("fixture")
    for index = 1, 12 do
        scheduled[index].callback()
        eq(scheduled[index + 1].delay, 30, "waiting keeps the report cadence")
    end
    eq(spawned, 0, "waiting never starts a report child")
    eq(online_checks, 0, "waiting avoids even the connectivity check")
    eq(position_checks, 0, "waiting avoids position preparation")
    eq(report:status().state, "waiting_for_download", "waiting state")
    eq(report:status().failure_count, 0, "waiting does not count as a failure")
    eq(report:status().consecutive_failures, 0, "waiting does not consume retry budget")
    downloading = false
    scheduled[13].callback()
    eq(spawned, 1, "next tick resumes once the download ends")
    eq(online_checks, 1, "connectivity checked only after resuming")
    eq(position_checks, 1, "fresh position prepared after resuming")
end)

test("stopping a deferred report invalidates its pending tick", function()
    local downloading, spawned = true, 0
    local report, _, scheduled = fixture(nil, {
        is_downloading = function() return downloading end,
    })
    report._start_job = function() spawned = spawned + 1; return true end
    report:start("fixture")
    scheduled[1].callback()
    report:stop("document_closed")
    downloading = false
    scheduled[2].callback()
    eq(spawned, 0, "stale waiting tick cannot restart a stopped report")
    eq(report:status().running, false, "report stays stopped")
end)

test("explicit position uploads keep their existing admission behavior", function()
    local attempts = 0
    local report = fixture(nil, { is_downloading = function() return true end })
    report._run_pipeline = function()
        attempts = attempts + 1
        return { accepted = true }
    end
    eq(report:upload_position("book", { chapter_uid = 22 }, 0), true,
        "explicit upload bypasses only the scheduled-report download gate")
    eq(attempts, 1, "explicit upload still invokes the existing pipeline")
end)

test("one reader session enters once and reports live position", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    local position = {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }
    report:_send("book", book, position, 0)
    report:_send("book", book, position, 30)
    eq(#records, 3, "enter plus two reports")
    eq(records[1].kind, "enter", "first request enters")
    eq(records[2].kind, "report", "second request reports")
    eq(records[2].chapter_uid, 22, "live chapter used")
    eq(records[2].chapter_offset, 150, "live offset used")
    eq(records[2].elapsed_seconds, 0, "progress-only report has zero time")
    eq(records[3].elapsed_seconds, 30, "time report keeps interval")
end)

test("report context restores SQLite catalog and backfills disk", function()
    local report = fixture()
    local db_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    report.library_db = {
        getChapters = function() return db_catalog end,
        putChapters = function() end,
    }
    cached_catalog = nil
    saved_catalog = nil
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    local context = report:_build_context("book", false, book)
    eq(context.chapters, db_catalog, "SQLite catalog restored")
    eq(saved_catalog, db_catalog, "catalog.json backfilled")
end)

test("report context backfills SQLite from catalog.json", function()
    local report = fixture()
    local disk_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    local written_catalog
    report.library_db = {
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_catalog = chapters
        end,
    }
    cached_catalog = disk_catalog
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    report:_build_context("book", false, book)
    eq(written_catalog, disk_catalog, "catalog.json backfills SQLite")
end)

print(string.format(
    "read_report_progress_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)
