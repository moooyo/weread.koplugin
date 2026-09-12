-- Phase workers for resumable chapter acquisition and bounded EPUB assembly.
-- The UI coordinator owns processes; acquisition never opens a database.
local Content = require("weread.lib.content")
local Crypto = require("weread.lib.crypto")
local Footnotes = require("weread.lib.footnotes")
local DownloadStore = require("weread.lib.download_store")
local Policy = require("weread.lib.download_policy")
local WorkerSettings = require("weread.lib.worker_settings")
local WeRead = require("weread.lib.protocol")
local logger = require("weread.lib.logger")
local ok_json, Json = pcall(require, "json")
if not ok_json then Json = require("rapidjson") end

local M = {}

local function read(path)
    local file = assert(io.open(path, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end

local function uid(chapter)
    return tostring(chapter.chapterUid or chapter.chapterId or "")
end

local function copy_book(book)
    local result = {}
    for key, value in pairs(book or {}) do
        local kind = type(value)
        if kind == "string" or kind == "number" or kind == "boolean" then result[key] = value end
    end
    return result
end

local function resolve_book(settings, input)
    local book = copy_book(input)
    book.cache_dir = Content.book_resolved_dir(settings, book.book_id or book.bookId, input)
    return book
end

local function check(context)
    if context and context.checkCancelled then context.checkCancelled() end
end

local function emit(context, state)
    check(context)
    if context and context.emit then context.emit(state) end
end

local function close(value)
    if value and value.close then pcall(value.close, value) end
end

local function with_store(settings, book, callback, cleanup_after)
    local store, err = DownloadStore:new(settings, book)
    assert(store, err)
    local ok, result = xpcall(function() return callback(store) end, debug.traceback)
    if cleanup_after and store.cleanupStale then pcall(store.cleanupStale, store, 0) end
    close(store)
    if not ok then error(result, 0) end
    return result
end

local function stats()
    return { candidates = 0, converted = 0, image_notes = 0, backlinks = 0,
        removed_note_blocks = 0, unresolved = 0, fallback = 0 }
end

local function add_stats(total, value)
    for key in pairs(total) do total[key] = total[key] + (tonumber(value and value[key]) or 0) end
end

local function prefix_assets(xhtml, assets, chapter_uid)
    local names = {}
    local prefix = chapter_uid:gsub("[^%w_-]", "_") .. "-"
    for _, asset in ipairs(assets) do
        local old_href = asset.href
        local name = assert(old_href:match("([^/]+)$"))
        asset.href = "images/" .. prefix .. name
        names["../" .. old_href] = "../" .. asset.href
        names[old_href] = asset.href
    end
    return (xhtml:gsub("src=([\"'])(.-)%1", function(quote, source)
        return "src=" .. quote .. (names[source] or source) .. quote
    end))
end

local function publication_key(store, book, chapters, cache, options)
    local keys, parts = {}, { "book-render-v2", tostring(options.suffix or "book"),
        tostring(options.single_chapter == true), tostring(options.separate_chapters == true),
        tostring(cache.book_footnotes_in_popup == true), tostring(book.title or ""),
        tostring(book.author or ""), tostring(book.cover or ""), tostring(book.intro or "") }
    for index, chapter in ipairs(chapters) do
        keys[index] = assert(store:chapterKey(chapter, cache.download_book_images == true))
        parts[#parts + 1] = keys[index]
    end
    return Crypto.sha256_hex(table.concat(parts, "\n")), keys
end

local function reusable_publication(store, key)
    local value = store:getPublication(key)
    if not value or value.resources_complete == false or #(value.failed_uids or {}) > 0 then return nil end
    if Content.validate_epub then
        local paths = value.chapter_paths or {}
        if not next(paths) then paths = { value.path } end
        for _, path in pairs(paths) do if not Content.validate_epub(path) then return nil end end
    end
    value.publication_key = key
    return value
end

local function network_scope(client, context, total, ordinal)
    local scope = { current = { stage = "source", index = ordinal or 1, total = total or 1 } }
    local activity = 0
    function scope:emit(stage, detail)
        self.current = { stage = stage, index = ordinal or 1, total = total or 1 }
        for key, value in pairs(detail or {}) do self.current[key] = value end
        emit(context, self.current)
    end
    if client.set_request_context then
        scope.previous = client:set_request_context {
            cancelled = context and context.cancelled,
            on_progress = function(info)
                check(context)
                if os.time() ~= activity then
                    activity = os.time()
                    scope.current.bytes = tonumber(info.bytes) or 0
                    emit(context, scope.current)
                end
            end,
            on_diagnostic = function(info) scope.diagnostic = info end,
        }
    end
    function scope:reset()
        self.diagnostic, client.last_request_error = nil, nil
    end
    function scope:restore()
        if client.set_request_context then client:set_request_context(self.previous) end
    end
    return scope
end

local function restore_scopes(scope, restore_auth)
    local scope_ok, scope_err = pcall(function() if scope then scope:restore() end end)
    local auth_ok, auth_err = pcall(function() if restore_auth then restore_auth() end end)
    if not scope_ok then return false, scope_err end
    return auth_ok, auth_err
end

local function failure_result(err, diagnostic, phase, attempt)
    local failure = { status = "failed", error = tostring(err), retryable = true }
    if diagnostic then
        failure.diagnostic = {}
        for _, key in ipairs({ "kind", "status", "api_code", "retryable", "retry_after_seconds", "message" }) do
            local value = diagnostic[key]
            if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
                failure.diagnostic[key] = value
            end
        end
        failure.retryable = diagnostic.retryable ~= false
    end
    if phase == "prepare" or phase == "persist" or failure.error:find("reader.psvts not found", 1, true) then
        failure.retryable, failure.pause = false, true
    end
    failure.pause = Policy.classify(failure, attempt or 1).pause
    return failure
end

function M.prepare(settings, input_book, chapters, options, context)
    options = options or {}
    local book = resolve_book(settings, input_book)
    local cache = settings:get("cache", {}) or {}
    check(context)
    return with_store(settings, book, function(store)
        if store.cleanupStale then store:cleanupStale(0) end
        local key, keys = publication_key(store, book, chapters, cache, options)
        local plan = { book = book, jobs = {}, publication_key = key,
            published = reusable_publication(store, key) }
        for ordinal, chapter in ipairs(chapters) do
            check(context)
            local bundle = store:getChapter(keys[ordinal])
            plan.jobs[#plan.jobs + 1] = { ordinal = ordinal, chapter_uid = uid(chapter),
                key = keys[ordinal], cached = bundle ~= nil }
            if bundle then
                plan.css_path = plan.css_path or bundle.css_path
                plan.content_format = plan.content_format or bundle.content_format
            end
        end
        emit(context, { stage = "prepared", index = 0, total = #chapters })
        return plan
    end)
end

function M.acquire(settings, client, input_book, chapter, options, context)
    options = options or {}
    check(context)
    -- Child-private credential updates may support its own request sequence;
    -- acquisition returns no credentials for another worker or the UI to merge.
    local _, restore_auth = WorkerSettings.capture(settings)
    local book, scope
    local files, phase = nil, "prepare"
    local ok, result = xpcall(function()
        book = resolve_book(settings, input_book)
        book._content_format = options.content_format or book._content_format
        scope = network_scope(client, context, options.total, options.ordinal)
        local err
        files, err = DownloadStore:newFiles(settings, book)
        assert(files, err)
        assert(type(options.key) == "string" and options.key ~= "", "Missing chapter cache key")
        local chapter_uid = uid(chapter)
        assert(chapter_uid ~= "", "Missing chapter UID")
        local workspace = assert(files:newWorkspace(options.key))
        local state = { workspace = workspace, source_options = { persist_source = false },
            retry_options = { attempts = Policy.MAX_ATTEMPTS, sleep = context and context.sleep,
                check_cancelled = context and context.checkCancelled } }
        if options.css_path then state.css = read(options.css_path) end
        scope:reset()
        phase = "source"
        scope:emit("source", { chapter_uid = chapter_uid, attempt = options.attempt or 1 })
        local xhtml = Content.fetch_single_chapter_source(client, settings, book, chapter, state)
        check(context)
        if client.last_request_error then
            error(client.last_request_error.message or "Chapter source request failed", 0)
        end
        local scan_ok, scan = pcall(Footnotes.scan_chapter, xhtml, chapter)
        phase = "persist"
        local annotation_raw = book._content_format == "txt"
        local annotation_path = workspace.path .. (annotation_raw and "/annotation.txt" or "/annotation.xhtml")
        local annotation_size
        do
            local original = state.raw_source or xhtml
            assert(files:writeText(annotation_path, original))
            annotation_size = #original
        end
        state.raw_source = nil
        phase = "resources"
        scope:reset()
        scope:emit("images", { chapter_uid = chapter_uid })
        state.image_progress = function(number, count)
            scope:emit("images", { chapter_uid = chapter_uid, current = number, count = count })
        end
        local finalized, assets = Content.finalize_single_chapter_content(client, settings, book, chapter, xhtml, state)
        check(context)
        phase = "persist"
        assets = assets or {}
        finalized = prefix_assets(finalized, assets, chapter_uid)
        local bundle = { chapter_uid = chapter_uid, assets = assets, content_format = book._content_format,
            resources_complete = state.resources_complete ~= false, xhtml_path = workspace.path .. "/source.xhtml" }
        assert(files:writeText(bundle.xhtml_path, finalized))
        if state.css then
            bundle.css_path = workspace.path .. "/style.css"
            assert(files:writeText(bundle.css_path, state.css))
        end
        if scan_ok then
            bundle.scan_path = workspace.path .. "/footnotes.json"
            assert(files:writeText(bundle.scan_path, Json.encode(scan)))
        end
        check(context)
        return { status = "ready", chapter_uid = chapter_uid, key = options.key, bundle = bundle,
            annotation_path = annotation_path, annotation_size = annotation_size,
            annotation_raw_text = annotation_raw, css_path = bundle.css_path, content_format = book._content_format }
    end, debug.traceback)
    close(files)
    local diagnostic = client.last_request_error or scope and scope.diagnostic
    local restored, restore_err = restore_scopes(scope, restore_auth)
    if ok and not restored then ok, result = false, restore_err end
    check(context)
    if not ok then
        if tostring(result):find("__weread_worker_cancelled__", 1, true) then error(result, 0) end
        return failure_result(result, diagnostic, phase, options.attempt)
    end
    return result
end

function M.commit(settings, input_book, chapter, ready, context)
    check(context)
    local book = resolve_book(settings, input_book)
    return with_store(settings, book, function(store)
        local cache = settings:get("cache", {}) or {}
        local expected_uid = uid(chapter)
        local expected_key = assert(store:chapterKey(chapter, cache.download_book_images == true))
        assert(type(ready) == "table" and ready.status == "ready", "Chapter acquisition is not ready")
        assert(ready.chapter_uid == expected_uid and ready.key == expected_key, "Chapter acquisition identity changed")
        assert(type(ready.bundle) == "table" and ready.bundle.chapter_uid == expected_uid, "Chapter bundle identity changed")
        local bundle = {}
        for key, value in pairs(ready.bundle) do bundle[key] = value end
        bundle.annotation_path = ready.annotation_path
        bundle.annotation_size = ready.annotation_size
        bundle.annotation_raw_text = ready.annotation_raw_text == true
        check(context)
        assert(store:putChapter(expected_key, bundle))
        check(context)
        if ready.annotation_path then
            local cached, cache_err = pcall(function()
                local original = read(ready.annotation_path)
                local source_book = copy_book(book)
                source_book._content_format = ready.content_format or bundle.content_format
                Content.cache_annotation_source(settings, source_book, chapter, original, ready.annotation_raw_text == true)
            end)
            if not cached then logger.warn("annotation source cache:", tostring(cache_err)) end
        end
        return { chapter_uid = expected_uid, key = expected_key, css_path = bundle.css_path,
            content_format = bundle.content_format, resources_complete = bundle.resources_complete ~= false }
    end)
end

function M.assemble(settings, client, input_book, chapters, options, context)
    options = options or {}
    check(context)
    local auth_result, restore_auth = WorkerSettings.capture(settings)
    local book, cache, scope
    local ok, result = xpcall(function()
        book = resolve_book(settings, input_book)
        cache = settings:get("cache", {}) or {}
        scope = network_scope(client, context, #chapters, #chapters)
        return with_store(settings, book, function(store)
            local key, keys = publication_key(store, book, chapters, cache, options)
            local excluded = {}
            for _, chapter_uid in ipairs(options.failed_uids or {}) do excluded[tostring(chapter_uid)] = true end
            local published = not next(excluded) and reusable_publication(store, key) or nil
            if published then scope:emit("cached"); published.auth = auth_result(); return published end
            local selected, bundles = {}, {}
            local value = { selected_uids = {}, failed_uids = {}, cache_dir = book.cache_dir,
                reader_url = book.reader_url, footnote_stats = stats(), resources_complete = true }
            for ordinal, chapter in ipairs(chapters) do
                check(context)
                local chapter_uid = uid(chapter)
                local bundle = not excluded[chapter_uid] and store:getChapter(keys[ordinal], { allow_incomplete = true }) or nil
                if bundle then
                    selected[#selected + 1] = chapter
                    value.selected_uids[#value.selected_uids + 1] = chapter_uid
                    bundles[chapter_uid] = bundle
                    if bundle.resources_complete == false then value.resources_complete = false end
                else value.failed_uids[#value.failed_uids + 1] = chapter_uid end
            end
            if #selected == 0 or (options.suffix == "full" and #value.failed_uids > 0) then
                value.auth = auth_result()
                return value
            end
            local compact_scans, css = {}, nil
            for _, chapter in ipairs(selected) do
                local chapter_uid = uid(chapter)
                local bundle = bundles[chapter_uid]
                if not css and bundle.css_path then css = read(bundle.css_path) end
                if bundle.scan_path then
                    local scan = Json.decode(read(bundle.scan_path))
                    compact_scans[chapter_uid] = { chapter_uid = chapter_uid, chapter = chapter, definitions = scan.definitions }
                end
            end
            local index_data = Footnotes.build_book_index(compact_scans, selected)
            local workspace = assert(store:newWorkspace(key))
            local bodies, assets, css_needed = {}, {}, false
            for index, chapter in ipairs(selected) do
                local chapter_uid = uid(chapter)
                local bundle = bundles[chapter_uid]
                emit(context, { stage = "footnotes", index = index, total = #selected, chapter_uid = chapter_uid })
                local original = read(bundle.xhtml_path)
                local transformed = original
                if bundle.scan_path then
                    local scan = Json.decode(read(bundle.scan_path))
                    local transformed_ok, output, current_stats = pcall(Footnotes.transform_chapter, original, scan, index_data)
                    if transformed_ok and Footnotes.validate(output) then
                        transformed = output
                        add_stats(value.footnote_stats, current_stats)
                        css_needed = css_needed or Footnotes.has_converted(current_stats)
                    else value.footnote_stats.fallback = value.footnote_stats.fallback + 1 end
                else value.footnote_stats.fallback = value.footnote_stats.fallback + 1 end
                local render_path = workspace.path .. "/chapter-" .. tostring(index) .. ".xhtml"
                assert(store:writeText(render_path, transformed))
                bodies[chapter_uid] = { path = render_path }
                for _, asset in ipairs(bundle.assets or {}) do assets[#assets + 1] = asset end
                collectgarbage("step")
            end
            if css_needed then css = (css or "") .. "\n" .. Footnotes.get_css(cache.book_footnotes_in_popup) end
            local archive_activity, archive_stage = 0, nil
            local archive_options = { check_cancelled = context and context.checkCancelled,
                progress = function(stage, number, total)
                    check(context)
                    if os.time() ~= archive_activity or stage ~= archive_stage or number == total then
                        archive_activity, archive_stage = os.time(), stage
                        scope:emit("epub", { archive_stage = stage, current = number, count = total })
                    end
                end }
            scope:emit("epub")
            local edition_book = copy_book(book)
            edition_book.cache_dir = workspace.path
            if options.single_chapter or options.separate_chapters then
                value.chapter_paths = {}
                for _, chapter in ipairs(selected) do
                    check(context)
                    local chapter_uid = uid(chapter)
                    local path = Content.save_chapter_epub(settings, edition_book, chapter,
                        bodies[chapter_uid], bundles[chapter_uid].assets, css, archive_options)
                    value.chapter_paths[chapter_uid] = path
                    value.path = value.path or path
                end
            else
                local cover
                local cover_url = WeRead.normalize_cover_url(book.cover)
                if cover_url and cover_url ~= "" then
                    for attempt = 1, Policy.MAX_ATTEMPTS do
                        check(context)
                        scope:reset()
                        local fetched, data = pcall(client.get_binary, client, cover_url)
                        check(context)
                        if not fetched and tostring(data):find("__weread_worker_cancelled__", 1, true) then
                            error(data, 0)
                        end
                        if fetched and type(data) == "string" and data ~= "" then cover = data; break end
                        local failure = failure_result(data or "Cover request failed", client.last_request_error or scope.diagnostic, "source", attempt)
                        local decision = Policy.classify(failure, attempt)
                        if decision.pause or not decision.retry then break end
                        if context and context.sleep then context.sleep(decision.delay) end
                    end
                    if not cover then value.resources_complete = false end
                end
                value.path = Content.save_book_epub(settings, edition_book, selected, bodies,
                    options.suffix, assets, css, cover, archive_options)
            end
            check(context)
            assert(store:putPublication(key, value))
            value.publication_key = key
            value.auth = auth_result()
            return value
        end, true)
    end, debug.traceback)
    local restored, restore_err = restore_scopes(scope, restore_auth)
    if ok and not restored then ok, result = false, restore_err end
    if not ok then error(result, 0) end
    return result
end

-- Preserve the serial entry point for compatibility and worker-level tests.
function M.run(settings, client, input_book, chapters, options, context)
    options = options or {}
    local auth_result, restore_auth = WorkerSettings.capture(settings)
    local ok, result = xpcall(function()
        local plan = M.prepare(settings, input_book, chapters, options, context)
        if plan.published then return plan.published end
        local css_path, content_format = plan.css_path, plan.content_format
        local failed = {}
        for ordinal, job in ipairs(plan.jobs) do
            check(context)
            if not job.cached then
                local complete = false
                for attempt = 1, Policy.MAX_ATTEMPTS do
                    local ready = M.acquire(settings, client, plan.book, chapters[ordinal], {
                        key = job.key, css_path = css_path, content_format = content_format,
                        ordinal = ordinal, total = #chapters, attempt = attempt,
                    }, context)
                    if ready.status == "ready" then
                        local committed = M.commit(settings, plan.book, chapters[ordinal], ready, context)
                        css_path = css_path or committed.css_path
                        content_format = committed.content_format or content_format
                        complete = true
                        break
                    end
                    local decision = Policy.classify(ready, attempt)
                    if decision.pause then
                        emit(context, { stage = "paused", index = ordinal, total = #chapters,
                            pause = true, http_status = decision.http_status,
                            error_kind = decision.error_kind, api_code = decision.api_code,
                            error = decision.error })
                        error(decision.error, 0)
                    end
                    if not decision.retry then break end
                    if context and context.sleep then context.sleep(decision.delay) end
                end
                if not complete then failed[#failed + 1] = job.chapter_uid end
                if ordinal < #plan.jobs and context and context.sleep then context.sleep(0.1) end
            end
        end
        local assembly_options = {}
        for key, value in pairs(options) do assembly_options[key] = value end
        assembly_options.failed_uids = failed
        return M.assemble(settings, client, plan.book, chapters, assembly_options, context)
    end, debug.traceback)
    if ok then
        local captured, auth = pcall(auth_result)
        if captured then result.auth = auth else ok, result = false, auth end
    end
    local restored, restore_err = restore_scopes(nil, restore_auth)
    if ok and not restored then ok, result = false, restore_err end
    if not ok then error(result, 0) end
    return result
end

return M
