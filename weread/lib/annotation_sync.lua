-- Resumable source preparation and document projection. Network batches and
-- matching deltas are persisted independently; cursors are only small hints.
local External = require("weread.lib.external_annotations")
local Chapters = require("weread.lib.annotation_chapters")
local Source = require("weread.lib.annotation_source")
local Annotations = require("weread.lib.annotations")
local Sync = {}
Sync.__index = Sync

local function unique_underlines(rows)
    local seen, result = {}, {}
    for _, row in ipairs(rows) do
        local range = type(row) == "table" and row.range
        if range and not seen[tostring(range)] then
            seen[tostring(range)] = true
            result[#result + 1] = row
        end
    end
    return result
end

local function batch_key(uid, epoch, index)
    return uid .. ":" .. tostring(epoch) .. ":" .. tostring(index)
end

function Sync:new(options)
    local job = setmetatable(options, self)
    job.index, job.completed = 0, 0
    job.thread = coroutine.create(function() return job:run() end)
    return job
end

function Sync:checkCancelled()
    if self.cancelled then error("Annotation sync paused.") end
    if self.check_cancelled then self.check_cancelled() end
end

function Sync:yield(stage, delay, detail)
    local state = { stage = stage, delay = delay or 0.01,
        index = self.index, total = #self.chapters, completed = self.completed }
    for key, value in pairs(detail or {}) do state[key] = value end
    coroutine.yield(state)
    self:checkCancelled()
end

function Sync:save(changes, condition)
    self:checkCancelled()
    assert(self.store:write(self.book_id, changes, condition),
        "Annotation task was superseded.")
end

function Sync:request(fn, progress)
    if self.offline then error("Annotation data is not cached. Connect to continue.") end
    for attempt = 1, 3 do
        self:yield(progress and progress.stage or "download",
            attempt == 1 and 0.3 or 2 ^ attempt, progress)
        local ok, data, err = fn()
        self:checkCancelled()
        if ok and type(data) == "table" then return data end
        local diagnostic = self.client.last_request_error
        if diagnostic and (diagnostic.status == 401 or diagnostic.status == 403
            or diagnostic.status == 429 or diagnostic.kind == "authentication") then
            error(err or diagnostic.message or "Annotation request paused", 0)
        end
        if attempt == 3 then error(err or "Invalid annotation response") end
    end
end

function Sync:prepareChapter(chapter, uid, stage)
    local store, book_id = self.store, self.book_id
    local condition = store:epochCondition(uid, stage.epoch)
    local plan = store:get(book_id, "underlines", uid)
    if not plan or plan.epoch ~= stage.epoch then
        local legacy = stage.legacy
        local rows = legacy and legacy.underlines
        if not rows then
            local result = self:request(function()
                local ok, data, err = self.client:get_chapter_underlines(book_id,
                    chapter.chapterUid or chapter.chapterId or chapter.chapter_uid)
                if ok and (type(data) ~= "table" or type(data.underlines) ~= "table") then
                    return false, nil, "Invalid underline response"
                end
                return ok, data, err
            end, { stage = "underlines" })
            rows = unique_underlines(result.underlines)
        end
        local ranges = {}
        for _, row in ipairs(rows) do ranges[#ranges + 1] = row.range end
        plan = { epoch = stage.epoch, underlines = rows,
            batches = self.client:build_chapter_review_batches(ranges) }
        local changes = {}
        if legacy then
            -- Older releases stored the entire underline list in the cursor
            -- and addressed batches without an epoch. Convert only once.
            changes[#changes + 1] = { kind = "batch", uid = uid }
            for index = 1, #plan.batches do
                local saved = store:get(book_id, "batch", uid .. ":" .. index)
                if saved then changes[#changes + 1] = { kind = "batch",
                    key = batch_key(uid, stage.epoch, index), uid = uid, value = saved } end
            end
        end
        stage.legacy = nil
        stage.batch_count = #plan.batches
        changes[#changes + 1] = { kind = "underlines", key = uid, uid = uid, value = plan }
        changes[#changes + 1] = { kind = "download", key = uid, uid = uid, value = stage }
        self:save(changes, condition)
    end
    local batches = plan.batches
    local completed = store:listKeys(book_id, "batch", uid)
    local downloaded, total, prefix = 0, 0, 0
    for index, batch in ipairs(batches) do
        total = total + #batch
        if completed[batch_key(uid, stage.epoch, index)] then downloaded = downloaded + #batch end
    end
    -- The durable completion set is authoritative. A cursor may lag or skip
    -- ahead after an older interrupted task, and must not cause missing work.
    for index, batch in ipairs(batches) do
        local key = batch_key(uid, stage.epoch, index)
        if not completed[key] then
            local result = self:request(function()
                local ok, data, err = self.client:get_chapter_reviews_batch(book_id,
                    chapter.chapterUid or chapter.chapterId or chapter.chapter_uid, batch)
                if ok and (type(data) ~= "table" or type(data.reviews) ~= "table") then
                    return false, nil, "Invalid thoughts response"
                end
                return ok, data, err
            end, { stage = "thoughts", current = downloaded, count = total })
            completed[key] = true
            while completed[batch_key(uid, stage.epoch, prefix + 1)] do prefix = prefix + 1 end
            stage.next_batch = prefix + 1
            self:save({
                { kind = "batch", key = key, uid = uid, value = result.reviews },
                { kind = "download", key = uid, uid = uid, value = stage },
            }, condition)
            downloaded = downloaded + #batch
            self:yield("thoughts", nil, { current = downloaded, count = total })
        end
    end
    local source = { book_id = book_id, chapter_uid = uid,
        revision = stage.revision, underlines = plan.underlines, reviews = {} }
    for index = 1, #batches do
        local rows = assert(store:get(book_id, "batch", batch_key(uid, stage.epoch, index)),
            "Missing saved thoughts batch")
        for _, review in ipairs(rows) do source.reviews[#source.reviews + 1] = review end
        self:yield("source")
    end
    local lookup = External.build_review_lookup(source.reviews)
    local missing = {}
    for _, row in ipairs(source.underlines) do
        if External.quote_for(row, source.reviews, lookup) == "" then missing[#missing + 1] = row end
    end
    if #missing > 0 then
        local original = store:get(book_id, "original", uid)
        if (not original or self.refresh) and self.fetch_source and not self.offline then
            self:yield("source", 0.3)
            local fetched = self.fetch_source(chapter)
            self:checkCancelled()
            original = type(fetched) == "table" and fetched or Source.index(fetched, {
                yield = function() self:yield("source") end,
            })
            self:save({ { kind = "original", key = uid, uid = uid, value = original } }, condition)
        end
        if original then
            for index, row in ipairs(missing) do
                row.markText = Source.quote(original, row.range, {
                    yield = function() self:yield("source") end,
                })
                if index % 32 == 0 then self:yield("source") end
            end
        end
    end
    local changes = {
        { kind = "source", key = uid, uid = uid, value = source },
        { kind = "source_status", key = uid, uid = uid,
            value = { revision = source.revision, total = #source.underlines } },
        { kind = "download", key = uid }, { kind = "underlines", key = uid },
        { kind = "batch", uid = uid }, { kind = "refresh", key = uid },
        { kind = "thought", uid = uid },
    }
    for index, review in ipairs(source.reviews) do
        local range = tostring(review.range or "")
        changes[#changes + 1] = { kind = "thought", key = uid .. ":" .. range, uid = uid,
            value = Annotations.buildThoughtPopupItems(review) }
        if index % 32 == 0 then self:yield("source") end
    end
    self:save(changes, condition)
    return source
end

function Sync:matchChapter(uid, source)
    local store, book_id = self.store, self.book_id
    local key = store:projectionKey(self.document_key, uid)
    local prefix = key .. ":"
    local condition = { kind = "source_status", key = uid,
        field = "revision", value = source.revision }
    local projection = store:get(book_id, "projection", key)
    if projection and projection.revision == source.revision
        and projection.matcher_version == External.MATCHER_VERSION then return projection end
    self:yield("match", nil, { current = 0, count = #source.underlines })
    local saved = store:get(book_id, "matching", key)
    if saved and (saved.revision ~= source.revision
        or saved.matcher_version ~= External.MATCHER_VERSION) then saved = nil end
    local batch_count = saved and saved.batch_count or 0
    if saved and saved.incremental then
        saved.records = {}
        for index = 1, batch_count do
            local rows = store:get(book_id, "match_batch", prefix .. index)
            if not rows then saved = nil; break end
            for _, row in ipairs(rows) do saved.records[#saved.records + 1] = row end
            self:yield("match", nil, { current = (saved.next_index or 1) - 1,
                count = #source.underlines })
        end
    elseif saved then
        for _, row in ipairs(saved.records or {}) do row.items = nil end
        batch_count = 1
        local cursor = {}
        for field, value in pairs(saved) do if field ~= "records" then cursor[field] = value end end
        cursor.incremental, cursor.batch_count = true, batch_count
        self:save({ { kind = "match_batch", uid = uid, prefix = prefix },
            { kind = "match_batch", key = prefix .. 1, uid = uid, value = saved.records or {} },
            { kind = "matching", key = key, uid = uid, value = cursor } }, condition)
    end
    if not saved then
        batch_count = 0
        self:save({ { kind = "matching", key = key },
            { kind = "match_batch", uid = uid, prefix = prefix } }, condition)
    end
    local match_current = saved and math.max(0, (saved.next_index or 1) - 1) or 0
    local records, stats = External.locate(self.document, { source }, {
        chapter_ranges = self.ranges, resume = saved, include_items = false,
        incremental_checkpoint = true,
        yield = function(current, count)
            if current then match_current = current end
            self:yield("match", current == nil and 0 or 0.01,
                { current = match_current, count = count or #source.underlines })
        end,
        checkpoint = function(state)
            batch_count = batch_count + 1
            local delta = state.records
            state.records = nil
            state.revision, state.matcher_version = source.revision, External.MATCHER_VERSION
            state.incremental, state.batch_count = true, batch_count
            self:save({
                { kind = "match_batch", key = prefix .. batch_count, uid = uid, value = delta },
                { kind = "matching", key = key, uid = uid, value = state },
            }, condition)
        end,
    })
    if projection and #(projection.records or {}) > 0 and stats.total > 0 and stats.located == 0 then
        error("No underlines could be matched. Previous chapter results were preserved.")
    end
    projection = { revision = source.revision, matcher_version = External.MATCHER_VERSION,
        records = records, stats = stats, complete = true }
    self:save({
        { kind = "projection", key = key, uid = uid, value = projection },
        { kind = "matching", key = key }, { kind = "match_batch", uid = uid, prefix = prefix },
        { kind = "status", key = key, uid = uid, value = { stats = stats,
            revision = source.revision, matcher_version = External.MATCHER_VERSION } },
    }, condition)
    return projection
end

function Sync:run()
    local store, book_id = self.store, self.book_id
    local refreshed = {}
    if self.refresh then
        for _, chapter in ipairs(self.chapters) do
            local uid = Chapters.uid(chapter)
            refreshed[uid] = store:beginDownload(book_id, uid, true)
        end
    end
    for index, chapter in ipairs(self.chapters) do
        self.index = index
        self:checkCancelled()
        local uid = Chapters.uid(chapter)
        local refreshing = store:get(book_id, "refresh", uid)
        local source_status = store:get(book_id, "source_status", uid)
        if source_status and not refreshing then
            local status = self.document_key and store:get(book_id, "status",
                store:projectionKey(self.document_key, uid))
            if not self.document or (status and status.revision == source_status.revision
                and status.matcher_version == External.MATCHER_VERSION) then
                self.completed = self.completed + 1
                if index % 8 == 0 or index == #self.chapters then self:yield("saved") end
                goto next_chapter
            end
        end
        local source = not refreshing and store:get(book_id, "source", uid)
        if not source then
            source = self:prepareChapter(chapter, uid,
                refreshed[uid] or store:beginDownload(book_id, uid, false))
        elseif not source_status then
            self:save({ { kind = "source_status", key = uid, uid = uid,
                value = { revision = source.revision, total = #(source.underlines or {}) } } },
                { kind = "source_status", key = uid, value = nil })
        end
        local projection = self.document and self:matchChapter(uid, source) or nil
        self.completed = self.completed + 1
        if self.on_chapter then self.on_chapter(uid, projection) end
        self:yield("saved")
        ::next_chapter::
    end
    return { stage = "complete", completed = self.completed, total = #self.chapters }
end

function Sync:step()
    if self.cancelled then return true, { stage = "paused" } end
    local ok, value = coroutine.resume(self.thread)
    if not ok then return nil, tostring(value) end
    return coroutine.status(self.thread) == "dead", value
end

return Sync
