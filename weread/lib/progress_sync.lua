local PositionMapper = require("weread.lib.position_mapper")

local logger = require("weread.lib.logger").scoped("ProgressSync")

local ProgressSync = {}
ProgressSync.__index = ProgressSync

local OPEN_DELAY_SECONDS = 0.6
local RESUME_RECHECK_SECONDS = 5 * 60
local PULL_RETRY_DELAY_SECONDS = 15
local PULL_MAX_RETRIES = 3
local BUSY_RETRY_SECONDS = 2
local BUSY_RETRY_LIMIT = 10
local SAME_THRESHOLD_PERCENT = 2
local SOURCE_CONFLICT_THRESHOLD_PERCENT = 2

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

local function document_path(document)
    if not document then return nil end
    return document.file
        or (type(document.getFilePath) == "function" and document:getFilePath())
end

function ProgressSync:new(options)
    options = options or {}
    assert(options.settings, "progress sync settings are required")
    assert(options.client, "progress sync client is required")
    assert(options.scheduler, "progress sync scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")
    assert(type(options.get_book) == "function", "get_book callback is required")
    assert(type(options.get_chapters) == "function", "get_chapters callback is required")
    assert(type(options.get_file_context) == "function", "get_file_context callback is required")
    assert(type(options.run_online) == "function", "run_online callback is required")
    assert(type(options.upload_position) == "function", "upload_position callback is required")
    assert(type(options.goto_fraction) == "function", "goto_fraction callback is required")
    assert(type(options.open_chapter) == "function", "open_chapter callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        scheduler = options.scheduler,
        get_document = options.get_document,
        get_footer = options.get_footer,
        detect_book = options.detect_book,
        get_book = options.get_book,
        get_chapters = options.get_chapters,
        refresh_catalog = options.refresh_catalog,
        get_file_context = options.get_file_context,
        run_online = options.run_online,
        upload_position = options.upload_position,
        goto_fraction = options.goto_fraction,
        open_chapter = options.open_chapter,
        is_online = options.is_online or function() return true end,
        is_downloading = options.is_downloading or function() return false end,
        on_choice = options.on_choice or function(context)
            context.keep_local()
        end,
        notify = options.notify or function() end,
        now = options.now or os.time,
        state = "idle",
        generation = 0,
        pull_retry_token = 0,
        automatic_uploads = {},
        dirty = false,
        verified = false,
    }
    return setmetatable(object, self)
end

function ProgressSync:_config()
    return self.settings:get("sync", {})
end

function ProgressSync:_persist(book_id, patch)
    book_id = tostring(book_id or "")
    if book_id == "" or type(patch) ~= "table" then return false end
    local books = self.settings:get("books", {})
    local book = books[book_id] or { book_id = book_id }
    for key, value in pairs(patch) do
        if value == false then
            book[key] = nil
        else
            book[key] = copy(value)
        end
    end
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return true
end

function ProgressSync:_local_fraction()
    local document = self.get_document()
    if not document then return nil end

    local footer = self.get_footer and self.get_footer()
    local footer_value = footer and tonumber(footer.percent_finished)
    if footer_value then
        if footer_value > 1 then footer_value = footer_value / 100 end
        return math.max(0, math.min(1, footer_value))
    end

    local page
    if type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then page = tonumber(value) end
    end
    if not page and type(document.getPageNumber) == "function" then
        local ok, value = pcall(document.getPageNumber, document)
        if ok then page = tonumber(value) end
    end
    local total
    if type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = tonumber(value) end
    end
    if page and total and total > 0 then
        return math.max(0, math.min(1, page / total))
    end
    local current_pos = tonumber(document.current_pos)
    local doc_height = tonumber(document.info and document.info.doc_height)
        or tonumber(document.doc_height)
    if current_pos and doc_height and doc_height > 0 then
        return math.max(0, math.min(1, current_pos / doc_height))
    end
    return nil
end

function ProgressSync:capture_local()
    local book_id = self.detect_book()
    if not book_id or is_mp_book(book_id) then
        return nil, "document_not_weread"
    end
    book_id = tostring(book_id)
    local document = self.get_document()
    local path = document_path(document)
    if not document or not path then return nil, "document_unavailable" end
    local cached = self.document_context
    local book
    local chapters
    local current_chapter
    local is_full_book
    if cached and cached.book_id == book_id and cached.path == path then
        book = cached.book
        chapters = cached.chapters
        current_chapter = cached.current_chapter
        is_full_book = cached.is_full_book
    else
        book = self.get_book(book_id)
        if type(book) ~= "table" then return nil, "book_not_found" end
        chapters = self.get_chapters(book)
        if type(chapters) ~= "table" or #chapters == 0 then
            return nil, "catalog_unavailable"
        end
        local _index
        _index, current_chapter, is_full_book =
            self.get_file_context(book, path)
        self.document_context = {
            book_id = book_id,
            book = book,
            chapters = chapters,
            current_chapter = current_chapter,
            is_full_book = is_full_book == true,
            path = path,
        }
    end
    local fraction = self:_local_fraction()
    if fraction == nil then return nil, "position_unavailable" end
    local position, reason = PositionMapper.local_to_remote(
        chapters,
        fraction,
        {
            is_full_book = is_full_book == true,
            current_chapter_uid = current_chapter
                and (current_chapter.chapterUid or current_chapter.chapterId),
            summary = book.summary or book.title or "",
        }
    )
    if not position then return nil, reason end
    position.book_id = book_id
    position.captured_at = self.now()
    position.current_chapter_uid = current_chapter
        and (current_chapter.chapterUid or current_chapter.chapterId)
    position.is_full_book = is_full_book == true
    return position, nil, {
        book_id = book_id,
        book = book,
        chapters = chapters,
        current_chapter = current_chapter,
        is_full_book = is_full_book == true,
        path = path,
    }
end

function ProgressSync:_mark_verified(book_id, reason, local_position, remote)
    self.current_book_id = tostring(book_id)
    self.verified = true
    self.verified_at = self.now()
    self.verified_reason = reason
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    self.state = "verified"
    self:_persist(book_id, {
        verified_at = self.verified_at,
        verified_source = reason,
        last_local_position = local_position,
        last_remote_position = remote,
        last_sync_error = false,
    })
    log("info", "verified:",
        "book=", tostring(book_id),
        "reason=", tostring(reason),
        "local=", tostring(local_position and local_position.percent or "-"),
        "remote=", tostring(remote and remote.percent or "-"))
end

function ProgressSync:_clear_verified(reason)
    self.verified = false
    self.verified_at = nil
    self.verified_reason = reason
    if self.current_book_id then
        self:_persist(self.current_book_id, {
            verified_at = false,
            verified_source = reason or "cleared",
        })
    end
end

function ProgressSync:_fetch_remote(book_id, chapters)
    local gateway
    local web
    local gateway_error
    local web_error
    if self.settings:is_api_configured() then
        local ok, result = pcall(self.client.get_progress, self.client, book_id)
        if ok then
            gateway, gateway_error = PositionMapper.normalize_remote(
                result, book_id, "gateway", chapters)
        else
            gateway_error = tostring(result)
        end
    end
    if self.settings:is_cookie_configured() then
        local ok, result = pcall(
            self.client.get_web_progress, self.client, book_id)
        if ok then
            web, web_error = PositionMapper.normalize_remote(
                result, book_id, "web", chapters)
        else
            web_error = tostring(result)
        end
    end
    local selected = PositionMapper.choose_remote(
        web,
        gateway,
        SOURCE_CONFLICT_THRESHOLD_PERCENT
    )
    if not selected then
        return nil, gateway_error or web_error or "remote_unavailable"
    end
    return selected
end

function ProgressSync:_apply_remote(remote, context, options)
    options = options or {}
    local target, reason = PositionMapper.remote_to_local(
        context.chapters,
        remote,
        {
            is_full_book = context.is_full_book,
            current_chapter_uid = context.current_chapter
                and (context.current_chapter.chapterUid
                    or context.current_chapter.chapterId),
        }
    )
    if not target then return false, reason end

    if target.requires_chapter_open then
        self:_clear_verified("switching_chapter")
        self.dirty = false
        self.pending_jump = {
            book_id = context.book_id,
            chapter_uid = target.chapter
                and (target.chapter.chapterUid or target.chapter.chapterId),
            fraction = target.fraction,
            remote = copy(remote),
            notify = options.manual == true,
        }
        self.state = "switching_chapter"
        local open_ok, opened, open_error = pcall(
            self.open_chapter, context.book, target.chapter)
        if not open_ok or opened == false then
            self.pending_jump = nil
            self.state = "error"
            return false, (open_ok and open_error or opened)
                or "target_chapter_unavailable"
        end
        return true
    end
    local ok, err = self.goto_fraction(target.fraction)
    if not ok then return false, err or "jump_failed" end
    self.dirty = false
    self:_mark_verified(
        context.book_id,
        "remote_selected",
        self.local_position,
        remote
    )
    if options.manual then
        self.notify("remote_applied", { position = remote })
    end
    self.scheduler:scheduleIn(0.15, function()
        local position = self:capture_local()
        if position then
            self.local_position = position
            self.dirty = false
            self:_persist(context.book_id, {
                last_local_position = position,
            })
        end
    end)
    return true
end

-- Session cookies may rotate when a download finishes. Fence deferred work
-- with account identity instead, so normal renewal retains a pending upload.
function ProgressSync:_upload_identity()
    local account = self.settings:get("account", {}) or {}
    local cookies = self.settings:get("cookies", {}) or {}
    return {
        user_vid = tostring(account.user_vid or ""),
        login_time = tostring(account.login_time or ""),
        cookie_vid = tostring(cookies.wr_vid or ""),
        api_key = tostring(self.settings:get("api_key", "")),
        connected = self.settings:is_cookie_configured() == true,
    }
end

function ProgressSync:_automatic_upload_current(pending)
    if self.automatic_uploads[pending.book_id] ~= pending then return false end
    local identity = self:_upload_identity()
    for key, value in pairs(pending.identity) do
        if identity[key] ~= value then
            self.automatic_uploads[pending.book_id] = nil
            local book = (self.settings:get("books", {}) or {})[pending.book_id]
            if book and PositionMapper.same_position(book.pending_upload_position, pending.position, 0)
                and book.pending_upload_position.captured_at == pending.position.captured_at then
                self:_persist(pending.book_id, {
                    pending_upload_position = false, pending_upload_reason = false,
                })
            end
            return false
        end
    end
    return true
end

function ProgressSync:_defer_automatic_upload(pending)
    if pending.scheduled then return end
    pending.scheduled = true
    self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, function()
        pending.scheduled = false
        if not self:_automatic_upload_current(pending) then return end
        self:_upload_snapshot(pending.position, pending.reason, false, pending)
    end)
end

function ProgressSync:_upload_snapshot(position, reason, show_result, pending)
    if type(position) ~= "table" then return false end
    local book_id = tostring(position.book_id or self.current_book_id or "")
    if book_id == "" then return false end
    local automatic = reason == "document_close" or reason == "suspend"
    local replay = pending ~= nil
    if automatic then
        if pending then
            if not self:_automatic_upload_current(pending) then return false end
        else
            pending = { book_id = book_id, position = copy(position), reason = reason,
                identity = self:_upload_identity(), generation = self.generation, attempts = 0 }
            self.automatic_uploads[book_id] = pending
        end
        position = pending.position
    else
        -- An explicit position replaces any older automatic snapshot for the
        -- same book, even while the automatic task is waiting for a download.
        self.automatic_uploads[book_id] = nil
        if self.uploading then return false end
    end
    if not replay then
        self:_persist(book_id, {
            pending_upload_position = position,
            pending_upload_reason = reason or "unspecified",
        })
    end
    if automatic and (self.is_downloading() or self.uploading) then
        self:_defer_automatic_upload(pending)
        return false
    end
    if not self.is_online() then
        if automatic then self.automatic_uploads[book_id] = nil end
        self.state = "offline"
        if show_result then self.notify("offline", {}) end
        return false
    end
    local owner, previous_state = {}, self.state
    self.upload_owner = owner
    self.uploading = true
    self.state = "uploading"
    local function release()
        if self.upload_owner ~= owner then return end
        self.upload_owner, self.uploading = nil, false
        if self.state == "uploading" then self.state = previous_state end
    end
    local attempts = automatic and pending.attempts or 0
    local attempt
    attempt = function()
        if self.upload_owner ~= owner then return end
        if automatic then
            if not self:_automatic_upload_current(pending) then release(); return end
            if self.is_downloading() then
                release()
                self:_defer_automatic_upload(pending)
                return
            end
        end
        attempts = attempts + 1
        if automatic then pending.attempts = attempts end
        local ok, accepted, outcome = pcall(
            self.upload_position,
            book_id,
            copy(position),
            0
        )
        if ok and not accepted and type(outcome) == "table"
            and outcome.error_kind == "busy"
            and attempts < BUSY_RETRY_LIMIT then
            self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, attempt)
            return
        end
        release()
        if automatic then self.automatic_uploads[book_id] = nil end
        if ok and accepted then
            if not automatic or (pending.generation == self.generation
                and tostring(self.current_book_id or "") == book_id
                and PositionMapper.same_position(self.local_position, position)) then
                self.state = "verified"
                self.dirty = false
            end
            self.last_uploaded_position = copy(position)
            self:_persist(book_id, {
                last_local_position = position,
                last_uploaded_position = position,
                last_upload_at = self.now(),
                pending_upload_position = false,
                pending_upload_reason = false,
                last_sync_error = false,
            })
            log("info", "upload accepted:",
                "book=", book_id,
                "percent=", tostring(position.percent),
                "reason=", tostring(reason))
            if show_result then
                self.notify("upload_success", { position = position })
            end
            return
        end
        local error_message = ok and type(outcome) == "table"
            and outcome.error or outcome
        self.state = "error"
        self:_persist(book_id, {
            last_sync_error = tostring(error_message or "upload_failed"),
        })
        log("warn", "upload failed:", tostring(error_message))
        if show_result then
            self.notify("upload_failed", {
                error = tostring(error_message or "upload_failed"),
            })
        end
    end
    local started = self.run_online("progress_upload", attempt)
    if not started then
        release()
        if automatic then self.automatic_uploads[book_id] = nil end
        self.state = "offline"
    end
    return started == true
end

function ProgressSync:_keep_local(local_position, remote, options)
    options = options or {}
    self.dirty = not PositionMapper.same_position(local_position, remote)
    self:_mark_verified(
        local_position.book_id,
        "local_selected",
        local_position,
        remote
    )
    if options.upload_now then
        self:_upload_snapshot(local_position, options.reason, true)
    elseif options.manual then
        self.notify("local_kept", { position = local_position })
    end
end

function ProgressSync:_resolve(local_position, remote, context, options)
    options = options or {}
    self.local_position = copy(local_position)
    self.remote_position = copy(remote)
    local comparison = PositionMapper.compare(
        local_position,
        remote,
        SAME_THRESHOLD_PERCENT
    )

    if comparison == "same" and not remote.conflict then
        self.dirty = false
        self:_mark_verified(
            context.book_id,
            "positions_match",
            local_position,
            remote
        )
        if options.manual then
            self.notify("already_synced", { position = local_position })
        end
        return
    end

    local ask = self:_config().ask_on_conflict ~= false
    if remote.conflict or ask then
        self.state = "awaiting_choice"
        local choice_generation = self.generation
        local function choice_is_current()
            return choice_generation == self.generation
                and tostring(self.detect_book() or "") == context.book_id
        end
        self.on_choice({
            book_title = context.book.title or context.book_id,
            local_position = copy(local_position),
            remote_position = copy(remote),
            source_conflict = remote.conflict == true,
            use_remote = function()
                if not choice_is_current() then return end
                local ok, reason = self:_apply_remote(
                    remote, context, { manual = options.manual })
                if not ok then
                    self.state = "error"
                    self.notify("jump_failed", { error = reason })
                end
            end,
            keep_local = function()
                if not choice_is_current() then return end
                self:_keep_local(local_position, remote, {
                    manual = options.manual,
                    upload_now = true,
                    reason = "explicit_local_choice",
                })
            end,
        })
        return
    end

    if comparison == "remote_ahead" then
        local ok, reason = self:_apply_remote(
            remote, context, { manual = options.manual })
        if not ok then
            self.state = "error"
            self.notify("jump_failed", { error = reason })
        end
    else
        self:_keep_local(local_position, remote, {
            manual = options.manual,
            upload_now = options.manual == true,
            reason = "manual_sync",
        })
    end
end

function ProgressSync:_defer_automatic_pull(options, retry_token)
    local pending = { generation = self.generation, retry_token = retry_token, options = copy(options) }
    pending.options.retry_token = retry_token
    self.deferred_pull = pending
    self.scheduler:scheduleIn(BUSY_RETRY_SECONDS, function()
        if self.deferred_pull ~= pending then return end
        self.deferred_pull = nil
        if pending.generation ~= self.generation or retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling or self.state == "awaiting_choice" then return end
        self:_pull(pending.options)
    end)
end

function ProgressSync:_schedule_pull_retry(options, retry_token)
    local attempt = (options.retry or 0) + 1
    if attempt > PULL_MAX_RETRIES then
        log("warn", "pull retries exhausted:",
            "book=", tostring(self.current_book_id))
        return false
    end
    local generation = self.generation
    self.scheduler:scheduleIn(PULL_RETRY_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        if retry_token ~= self.pull_retry_token then return end
        if self.verified or self.pulling then return end
        if self.state == "awaiting_choice" then return end
        self:_pull({
            manual = false,
            retry = attempt,
            retry_token = retry_token,
        })
    end)
    log("info", "pull retry scheduled:",
        "book=", tostring(self.current_book_id),
        "attempt=", tostring(attempt),
        "delay=", tostring(PULL_RETRY_DELAY_SECONDS))
    return true
end

function ProgressSync:_pull(options)
    options = options or {}
    if self.pulling then return false end
    local retry_token = options.retry_token
    if retry_token == nil then
        self.pull_retry_token = self.pull_retry_token + 1
        retry_token = self.pull_retry_token
    elseif retry_token ~= self.pull_retry_token then
        return false
    end
    if options.manual ~= true and self.is_downloading() then
        self.state = "waiting"
        self:_defer_automatic_pull(options, retry_token)
        return false
    end
    local local_position, reason, context = self:capture_local()
    if not local_position then
        if not (options.manual == true
            and reason == "catalog_unavailable"
            and type(self.refresh_catalog) == "function") then
            if options.manual then
                self.notify("local_unavailable", { error = reason })
            end
            return false
        end
    end
    if not self.settings:is_api_configured()
        and not self.settings:is_cookie_configured() then
        if options.manual then self.notify("authentication_required", {}) end
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
        return false
    end

    local generation = self.generation
    self.pulling = true
    self.state = "pulling"
    local started = self.run_online("progress_pull", function()
        if generation ~= self.generation or retry_token ~= self.pull_retry_token
            or (context and tostring(self.detect_book() or "") ~= context.book_id) then
            self.pulling = false
            return
        end
        if options.manual ~= true and self.is_downloading() then
            self.pulling = false
            self.state = "waiting"
            self:_defer_automatic_pull(options, retry_token)
            return
        end
        if not local_position then
            local book_id = tostring(self.detect_book() or "")
            local refresh_ok, refreshed, refresh_error = pcall(
                self.refresh_catalog, book_id)
            if not refresh_ok then
                refresh_error = refreshed
                refreshed = nil
            end
            self.document_context = nil
            local_position, reason, context = self:capture_local()
            if not local_position then
                self.pulling = false
                self.state = "error"
                self.notify("local_unavailable", {
                    error = refresh_error or reason,
                })
                return
            end
            if type(refreshed) ~= "table" or #refreshed == 0 then
                log("warn", "catalog refresh returned no chapters for:", book_id)
            end
        end
        local remote, pull_error = self:_fetch_remote(
            context.book_id,
            context.chapters
        )
        self.pulling = false
        if generation ~= self.generation
            or tostring(self.detect_book() or "") ~= context.book_id then
            return
        end
        if not remote then
            self.state = "error"
            self:_persist(context.book_id, {
                last_pull_at = self.now(),
                last_sync_error = tostring(pull_error),
            })
            if options.manual then
                self.notify("pull_failed", { error = tostring(pull_error) })
            end
            return
        end
        self:_persist(context.book_id, {
            last_remote_position = remote,
            last_local_position = local_position,
            last_pull_at = self.now(),
            last_sync_error = false,
        })
        self:_resolve(local_position, remote, context, options)
    end, { silent_offline = true })
    if not started then
        self.pulling = false
        self.state = "offline"
        if options.manual then
            self.notify("offline", {})
        else
            self:_schedule_pull_retry(options, retry_token)
        end
    end
    return started == true
end

function ProgressSync:_apply_pending_jump(book_id)
    local pending = self.pending_jump
    if not pending or tostring(pending.book_id) ~= tostring(book_id) then
        return false
    end
    local local_position, _reason, context = self:capture_local()
    if not context or not context.current_chapter
        or tostring(context.current_chapter.chapterUid or context.current_chapter.chapterId)
            ~= tostring(pending.chapter_uid) then
        return false
    end
    self.pending_jump = nil
    local ok, err = self.goto_fraction(pending.fraction)
    if not ok then
        self.state = "error"
        self.notify("jump_failed", { error = err })
        return true
    end
    self.dirty = false
    self:_mark_verified(
        book_id,
        "remote_chapter_applied",
        local_position,
        pending.remote
    )
    if pending.notify then
        self.notify("remote_applied", { position = pending.remote })
    end
    self.scheduler:scheduleIn(0.15, function()
        local position = self:capture_local()
        if position then
            self.local_position = position
            self:_persist(book_id, { last_local_position = position })
        end
    end)
    return true
end

function ProgressSync:cancel_pending_jump(reason)
    if not self.pending_jump then return false end
    self.pending_jump = nil
    self.dirty = false
    self.state = "unverified"
    self:_clear_verified(tostring(reason or "pending_jump_cancelled"))
    return true
end

function ProgressSync:on_reader_ready()
    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = nil
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
    self.verified = false
    self.dirty = false
    self.state = "waiting"

    self.scheduler:scheduleIn(OPEN_DELAY_SECONDS, function()
        if generation ~= self.generation then return end
        local book_id = self.detect_book()
        if not book_id or is_mp_book(book_id) then
            self.state = "unsupported"
            return
        end
        book_id = tostring(book_id)
        self.current_book_id = book_id
        if self:_apply_pending_jump(book_id) then return end

        local local_position, reason = self:capture_local()
        if not local_position then
            self.state = "unsafe"
            log("warn", "local position unavailable:", tostring(reason))
            return
        end
        self.local_position = local_position
        self:_persist(book_id, { last_local_position = local_position })
        if self:_config().pull_on_open ~= true then
            self.state = "unverified"
            return
        end
        self:_pull({ manual = false })
    end)
end

function ProgressSync:on_page_update()
    if not self.current_book_id then return end
    local position = self:capture_local()
    if not position then return end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
end

function ProgressSync:on_close_document()
    local position = self:capture_local() or self.local_position
    if position and self.verified
        and self:_config().upload_on_close == true then
        if not self.local_position
            or not PositionMapper.same_position(position, self.local_position) then
            self.dirty = true
        end
        if self.dirty then
            self:_upload_snapshot(position, "document_close", false)
        end
    end
    self.generation = self.generation + 1
    self.current_book_id = nil
    self.verified = false
    self.local_position = nil
    self.remote_position = nil
    self.document_context = nil
end

function ProgressSync:on_suspend()
    self.suspended_at = self.now()
    local position = self:capture_local() or self.local_position
    if position and self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    if position and self.verified and self.dirty
        and self:_config().upload_on_close == true then
        self:_upload_snapshot(position, "suspend", false)
    end
end

function ProgressSync:on_resume()
    local slept = self.suspended_at and self.now() - self.suspended_at or 0
    self.suspended_at = nil
    if slept >= RESUME_RECHECK_SECONDS
        and self:_config().pull_on_open == true then
        self:_clear_verified("resume_recheck")
        self:_pull({ manual = false })
    end
end

function ProgressSync:sync_now()
    return self:_pull({ manual = true })
end

function ProgressSync:position_for_report(book_id)
    local current = self.detect_book()
    if not current or tostring(current) ~= tostring(book_id)
        or is_mp_book(book_id) then
        return nil, nil, false
    end
    if not self.verified then
        return nil, "progress_unverified", true
    end
    local position, reason = self:capture_local()
    if not position then
        return nil, reason or "position_unavailable", true
    end
    if self.local_position
        and not PositionMapper.same_position(position, self.local_position) then
        self.dirty = true
    end
    self.local_position = position
    return position, nil, true
end

function ProgressSync:status()
    return {
        state = self.state,
        book_id = self.current_book_id,
        verified = self.verified,
        dirty = self.dirty,
        pulling = self.pulling == true,
        uploading = self.uploading == true,
        local_position = copy(self.local_position),
        remote_position = copy(self.remote_position),
    }
end

return ProgressSync
