-- Exercise durable pipeline state with real SQLite and deterministic responses.
package.path = "./?.lua;" .. package.path
local helper = require("spec.helpers.annotation_test_store")
local json = require("json")
local Sync = require("weread.lib.annotation_sync")
local Annotations = require("weread.lib.annotations")
local External = require("weread.lib.external_annotations")

local function clone(value)
    return json.decode(json.encode(value))
end

local function observed_store()
    local store = helper.new()
    local observer = { writes = {} }
    local write = store.write
    function store:write(book_id, changes, condition)
        local snapshot = clone(changes)
        local saved = write(self, book_id, changes, condition)
        if saved then observer.writes[#observer.writes + 1] = snapshot end
        return saved
    end
    return store, observer
end

local function rows_for(count)
    local rows = {}
    for index = 1, count do
        rows[index] = {
            range = (index * 4) .. "-" .. (index * 4 + 3),
            markText = string.format("quote%04d", index),
        }
    end
    return rows
end

local function reviews_for(batch, label)
    local reviews = {}
    for _, entry in ipairs(batch) do
        reviews[#reviews + 1] = { range = entry.range, pageReviews = {
            { review = { content = (label or "thought") .. ":" .. entry.range,
                author = { name = "author" } } },
        } }
    end
    return reviews
end

local function fake_client(rows, batch_size, label)
    local client = { calls = { underlines = 0, reviews = {} } }
    function client:build_chapter_review_batches(ranges)
        local batches = {}
        for first = 1, #ranges, batch_size or 8 do
            local batch = {}
            for index = first, math.min(first + (batch_size or 8) - 1, #ranges) do
                batch[#batch + 1] = { range = ranges[index], count = 20, maxIdx = 0, synckey = 0 }
            end
            batches[#batches + 1] = batch
        end
        return batches
    end
    function client:get_chapter_underlines()
        self.calls.underlines = self.calls.underlines + 1
        if self.on_underlines then self.on_underlines() end
        return true, { underlines = clone(rows) }
    end
    function client:get_chapter_reviews_batch(_book_id, _uid, batch)
        self.calls.reviews[#self.calls.reviews + 1] = clone(batch)
        if self.on_reviews then self.on_reviews(batch) end
        return true, { reviews = reviews_for(batch, label) }
    end
    return client
end

local document = {
    findAllText = function(_self, quote)
        local index = assert(tonumber(quote:match("(%d+)$")))
        return { { start = tostring(index * 10), ["end"] = tostring(index * 10 + 5) } }
    end,
    compareXPointers = function(_self, first, last)
        first, last = tonumber(first), tonumber(last)
        return first < last and 1 or first > last and -1 or 0
    end,
}

local function job_for(store, client, book_id, options)
    local args = { store = store, client = client, book_id = book_id,
        chapters = { { chapterUid = "1" } } }
    for key, value in pairs(options or {}) do args[key] = value end
    return Sync:new(args)
end

local function finish(job)
    for _ = 1, 10000 do
        local done, state = job:step()
        if done == nil then return nil, state end
        if done then return true, state end
    end
    error("pipeline did not terminate")
end

local function until_state(job, predicate)
    for _ = 1, 1000 do
        local done, state = job:step()
        assert(done ~= nil, state)
        if predicate(state) then return state end
        assert(not done, "pipeline finished before reaching the requested state")
    end
    error("pipeline did not reach the requested state")
end

local function assert_small_download_cursor(value)
    assert(value.underlines == nil and value.reviews == nil and value.batches == nil,
        "download cursor embedded chapter-sized arrays")
    assert(value.legacy == nil, "converted download cursor retained its legacy snapshot")
    assert(#json.encode(value) < 256, "download cursor grew with chapter data")
end

local function assert_plan_written_once(observer, count)
    local plans, cursors = 0, 0
    for _, changes in ipairs(observer.writes) do
        for _, change in ipairs(changes) do
            if change.kind == "underlines" and change.value ~= nil then
                plans = plans + 1
                assert(#change.value.underlines == count, "immutable plan lost underlines")
            elseif change.kind == "download" and change.value ~= nil then
                cursors = cursors + 1
                assert_small_download_cursor(change.value)
            end
        end
    end
    assert(plans == 1 and cursors > 1, "the pipeline rewrote its immutable plan for each batch")
end

local function matching_write_metrics(observer, count)
    local metrics = { delta_rows = 0, delta_batches = 0, bytes = 0, projections = 0 }
    local seen = {}
    for _, changes in ipairs(observer.writes) do
        for _, change in ipairs(changes) do
            assert(change.kind ~= "source" and change.kind ~= "source_status" and change.kind ~= "thought",
                "matcher-only work rewrote shared source or thoughts")
            if change.value ~= nil then
                metrics.bytes = metrics.bytes + #json.encode(change.value)
                if change.kind == "match_batch" then
                    metrics.delta_batches = metrics.delta_batches + 1
                    assert(#change.value <= 16, "matching checkpoint repeated an earlier batch")
                    for _, record in ipairs(change.value) do
                        assert(record.items == nil, "matching delta retained thought items")
                        assert(not seen[record.id], "matching deltas repeated a record")
                        seen[record.id] = true
                        metrics.delta_rows = metrics.delta_rows + 1
                    end
                elseif change.kind == "matching" then
                    assert(change.value.records == nil and change.value.underlines == nil,
                        "matching cursor embedded accumulated records")
                    assert(change.value.incremental == true and #json.encode(change.value) < 768,
                        "matching cursor was not a bounded incremental checkpoint")
                elseif change.kind == "projection" then
                    metrics.projections = metrics.projections + 1
                    assert(#change.value.records == count, "final projection lost checkpoint records")
                    for _, record in ipairs(change.value.records) do
                        assert(record.items == nil, "final projection retained thought items")
                    end
                end
            end
        end
    end
    assert(metrics.delta_rows == count and metrics.delta_batches == math.ceil(count / 16),
        "matching delta writes were not linear in the number of records")
    assert(metrics.projections == 1, "matching did not publish exactly one final projection")
    return metrics
end

local function run_storage_case(count)
    local book_id = "storage-" .. count
    local store, observer = observed_store()
    local client = fake_client(rows_for(count), 8)
    assert(finish(job_for(store, client, book_id)))
    assert_plan_written_once(observer, count)
    assert(store:get(book_id, "download", "1") == nil
        and store:get(book_id, "underlines", "1") == nil, "committed source retained staging cursors")
    local source_before = json.encode(store:get(book_id, "source", "1"))
    local thoughts_before = json.encode(store:list(book_id, "thought"))
    observer.writes = {}
    local builds, original_builder = 0, Annotations.buildThoughtPopupItems
    Annotations.buildThoughtPopupItems = function(...)
        builds = builds + 1
        return original_builder(...)
    end
    local ok, err = finish(job_for(store, client, book_id, {
        document = document, document_key = "document", offline = true,
    }))
    Annotations.buildThoughtPopupItems = original_builder
    assert(ok, err)
    assert(builds == 0, "matcher built thought items that it later discarded")
    assert(json.encode(store:get(book_id, "source", "1")) == source_before
        and json.encode(store:list(book_id, "thought")) == thoughts_before,
        "matcher-only work changed shared source or thought contents")
    assert(next(store:listKeys(book_id, "match_batch", "1")) == nil
        and store:get(book_id, "matching", "document:1") == nil,
        "published projection retained matching staging rows")
    return matching_write_metrics(observer, count)
end

local small = run_storage_case(128)
local large = run_storage_case(256)
assert(large.bytes <= small.bytes * 2.25, "doubling matches caused superlinear serialized writes")

-- A persisted completion set, not next_batch, decides which requests remain.
local gap_store = helper.new()
local gap_rows = rows_for(3)
local gap_client = fake_client(gap_rows, 1)
local gap_stage = gap_store:beginDownload("gap", "1", false)
local gap_ranges = {}
for _, row in ipairs(gap_rows) do gap_ranges[#gap_ranges + 1] = row.range end
local gap_batches = gap_client:build_chapter_review_batches(gap_ranges)
gap_stage.next_batch, gap_stage.batch_count = 99, #gap_batches
assert(gap_store:write("gap", {
    { kind = "download", key = "1", uid = "1", value = gap_stage },
    { kind = "underlines", key = "1", uid = "1", value = {
        epoch = gap_stage.epoch, underlines = gap_rows, batches = gap_batches } },
    { kind = "batch", key = "1:" .. gap_stage.epoch .. ":1", uid = "1", value = reviews_for(gap_batches[1]) },
    { kind = "batch", key = "1:" .. gap_stage.epoch .. ":3", uid = "1", value = reviews_for(gap_batches[3]) },
}))
assert(finish(job_for(gap_store, gap_client, "gap")))
assert(gap_client.calls.underlines == 0 and #gap_client.calls.reviews == 1
    and gap_client.calls.reviews[1][1].range == gap_rows[2].range,
    "resume did not request only the missing out-of-order batch")
local gap_source = gap_store:get("gap", "source", "1")
for index, row in ipairs(gap_rows) do
    assert(gap_source.reviews[index].range == row.range, "completion order changed committed review order")
end

-- Convert old chapter-sized cursors and unversioned batch keys before resuming.
local legacy_store = helper.new()
local legacy_client = fake_client(gap_rows, 1)
legacy_store:put("legacy", "generation", "1", 7, "1")
legacy_store:put("legacy", "download", "1", {
    underlines = gap_rows, next_batch = 99, revision = "7",
}, "1")
legacy_store:put("legacy", "batch", "1:1", reviews_for(gap_batches[1]), "1")
legacy_store:put("legacy", "batch", "1:3", reviews_for(gap_batches[3]), "1")
local legacy_job = job_for(legacy_store, legacy_client, "legacy")
until_state(legacy_job, function() return legacy_store:get("legacy", "underlines", "1") ~= nil end)
local migrated = legacy_store:get("legacy", "download", "1")
assert_small_download_cursor(migrated)
assert(migrated.epoch == 8 and legacy_client.calls.underlines == 0,
    "legacy migration discarded its existing underline snapshot or generation")
assert(legacy_store:get("legacy", "batch", "1:1") == nil
    and legacy_store:get("legacy", "batch", "1:3") == nil,
    "legacy migration retained unversioned batch keys")
assert(legacy_store:get("legacy", "batch", "1:8:1")
    and legacy_store:get("legacy", "batch", "1:8:3"), "legacy migration lost saved batch payloads")
assert(finish(legacy_job))
assert(#legacy_client.calls.reviews == 1 and legacy_client.calls.reviews[1][1].range == gap_rows[2].range,
    "legacy resume re-downloaded saved batches or skipped its gap")

-- Migrating complete legacy downloads must preserve a partial matching cursor.
local resume_store = helper.new()
local resume_client = fake_client(gap_rows, 1)
local resume_book, resume_key = "legacy-matching", "legacy-document:1"
resume_store:put(resume_book, "generation", "1", 7, "1")
resume_store:put(resume_book, "download", "1", {
    underlines = gap_rows, next_batch = 4, revision = "7",
}, "1")
for index, batch in ipairs(gap_batches) do
    resume_store:put(resume_book, "batch", "1:" .. index, reviews_for(batch), "1")
end
local saved_record = {
    id = resume_book .. ":1:" .. gap_rows[1].range, pos0 = "10", pos1 = "15",
    text = gap_rows[1].markText, book_id = resume_book, chapter_uid = "1",
    range = gap_rows[1].range, items = { { content = "legacy popup item" } },
}
resume_store:put(resume_book, "matching", resume_key, {
    revision = "7", matcher_version = External.MATCHER_VERSION,
    records = { saved_record },
    stats = { total = 3, located = 1, missing_text = 0, unmatched = 0, partial = 0 },
    next_index = 2, cursor_xp = "10", cursor_byte = 0, previous_range = 4,
}, "1")
local searched_quotes = {}
local resume_document = {
    compareXPointers = document.compareXPointers,
    findAllText = function(self, quote)
        searched_quotes[#searched_quotes + 1] = quote
        return document.findAllText(self, quote)
    end,
}
assert(finish(job_for(resume_store, resume_client, resume_book, {
    document = resume_document, document_key = "legacy-document",
})))
assert(resume_client.calls.underlines == 0 and #resume_client.calls.reviews == 0,
    "legacy matching resume downloaded an already complete source again")
assert(#searched_quotes == 2 and searched_quotes[1] == gap_rows[2].markText
    and searched_quotes[2] == gap_rows[3].markText,
    "legacy matching resume recomputed a saved record or skipped an unfinished record")
local resumed_projection = resume_store:get(resume_book, "projection", resume_key)
assert(resume_store:get(resume_book, "generation", "1") == 8
    and resumed_projection.revision == "7", "migration confused task ownership with source revision")
assert(#resumed_projection.records == 3 and resumed_projection.stats.located == 3
    and resumed_projection.stats.total == 3, "legacy matching statistics or records were duplicated")
assert(resumed_projection.records[1].id == saved_record.id
    and resumed_projection.records[1].pos0 == saved_record.pos0
    and resumed_projection.records[1].items == nil,
    "legacy matching did not preserve the saved coordinate as a lightweight record")
assert(resume_store:get(resume_book, "matching", resume_key) == nil
    and next(resume_store:listKeys(resume_book, "match_batch", "1")) == nil,
    "legacy matching resume left committed checkpoint data behind")

-- The old response returns only after a newer refresh has published its data.
local race_store = helper.new()
local race_rows = rows_for(1)
local old_client = fake_client(race_rows, 1, "old")
old_client.on_reviews = function() coroutine.yield({ stage = "response_in_flight" }) end
local old_job = job_for(race_store, old_client, "refresh-race")
until_state(old_job, function(state) return state.stage == "response_in_flight" end)
local old_epoch = race_store:get("refresh-race", "generation", "1")
local fresh_client = fake_client(race_rows, 1, "fresh")
assert(finish(job_for(race_store, fresh_client, "refresh-race", { refresh = true })))
local fresh_source = json.encode(race_store:get("refresh-race", "source", "1"))
local fresh_thoughts = json.encode(race_store:list("refresh-race", "thought"))
assert(race_store:get("refresh-race", "generation", "1") > old_epoch,
    "refresh did not revoke the earlier generation")
local old_done, old_error = finish(old_job)
assert(old_done == nil and old_error:find("superseded", 1, true),
    "a response from the revoked generation was accepted")
assert(json.encode(race_store:get("refresh-race", "source", "1")) == fresh_source
    and json.encode(race_store:list("refresh-race", "thought")) == fresh_thoughts,
    "a late old response replaced newer source or thoughts")
assert(race_store:get("refresh-race", "download", "1") == nil
    and next(race_store:listKeys("refresh-race", "batch", "1")) == nil,
    "a late old response recreated staging after the refresh committed")

-- Cancellation observed immediately after a response must precede its write.
for _, response_kind in ipairs({ "underlines", "reviews" }) do
    local cancel_store = helper.new()
    local cancel_client = fake_client(race_rows, 1)
    local cancel_job = job_for(cancel_store, cancel_client, "cancel-" .. response_kind)
    cancel_client["on_" .. response_kind] = function() cancel_job.cancelled = true end
    local done, err = finish(cancel_job)
    assert(done == nil and err:find("paused", 1, true), "post-response cancellation did not stop the task")
    local book_id = "cancel-" .. response_kind
    assert(cancel_store:get(book_id, "source", "1") == nil
        and cancel_store:get(book_id, "source_status", "1") == nil,
        "cancelled response published a chapter source")
    assert(next(cancel_store:listKeys(book_id, "batch", "1")) == nil,
        "cancelled response persisted a review batch")
    local cursor = cancel_store:get(book_id, "download", "1")
    assert(cursor and cursor.next_batch == 1, "cancelled response advanced the durable cursor")
    if response_kind == "underlines" then
        assert(cancel_store:get(book_id, "underlines", "1") == nil,
            "cancelled underline response persisted an immutable plan")
    end
end

helper.cleanup()
print(string.format("annotation_pipeline_storage_spec: durable plans, delta writes, resume gaps, migration, refresh fencing and cancellation passed; matching bytes 128=%d 256=%d",
    small.bytes, large.bytes))
