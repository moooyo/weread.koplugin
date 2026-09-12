-- Exercise the full background pipeline with deterministic transport/storage.
package.path = "./?.lua;./?/init.lua;" .. package.path
local function encode(value)
    if type(value) == "table" then
        local out = {}
        for key, item in pairs(value) do out[#out + 1] = "[" .. encode(key) .. "]=" .. encode(item) end
        return "{" .. table.concat(out, ",") .. "}"
    end
    if type(value) == "string" then return string.format("%q", value) end
    return tostring(value)
end
local function clone(value) return assert(loadstring("return " .. encode(value)))() end
package.preload["json"] = function()
    return { encode = encode, decode = function(value) return assert(loadstring("return " .. value))() end }
end
package.preload["weread.lib.logger"] = function()
    local logger = { info = function() end, warn = function() end, err = function() end }
    logger.scoped = function() return logger end
    return logger
end
local root = os.tmpname()
os.remove(root)
assert(os.execute("mkdir -p " .. string.format("%q", root)))
local function write(path, text)
    local file = assert(io.open(path, "wb")); assert(file:write(text)); file:close()
end
local function read(path)
    local file = assert(io.open(path, "rb")); local text = file:read("*a"); file:close(); return text
end
local saved, publications, workspace_id, publication_count = {}, {}, 0, 0
local store_opened, store_closed, files_opened, files_closed, chapter_writes = 0, 0, 0, 0, 0
local chapter_reads = {}
local Store = {}
local Files = {}
function Store:new()
    store_opened = store_opened + 1
    return setmetatable({}, { __index = self })
end
function Store:newFiles()
    files_opened = files_opened + 1
    return setmetatable({}, { __index = Files })
end
function Store:chapterKey(chapter, images)
    return require("weread.lib.crypto").sha256_hex(tostring(chapter.chapterUid) .. tostring(images))
end
function Store:getChapter(key, options)
    chapter_reads[#chapter_reads + 1] = { key = key, allow_incomplete = options and options.allow_incomplete }
    local value = saved[key]
    return value and (value.resources_complete ~= false or (options and options.allow_incomplete))
        and clone(value) or nil
end
function Store:putChapter(key, value)
    chapter_writes = chapter_writes + 1
    saved[key] = clone(value)
    return true
end
function Store:newWorkspace()
    workspace_id = workspace_id + 1
    local path = root .. "/attempt-" .. workspace_id
    assert(os.execute("mkdir -p " .. string.format("%q", path)))
    return { path = path, incoming_dir = path, asset_dir = path }
end
function Store:writeText(path, text) write(path, text); return true end
Files.newWorkspace = Store.newWorkspace
Files.writeText = Store.writeText
function Files:close()
    assert(not self.closed, "file workspace must not close twice")
    self.closed = true
    files_closed = files_closed + 1
end
function Store:getPublication(key) return publications[key] and clone(publications[key]) end
function Store:putPublication(key, value)
    publication_count = publication_count + 1
    publications[key] = clone(value)
    return true
end
function Store:close()
    assert(not self.closed, "store must not close twice")
    self.closed = true
    store_closed = store_closed + 1
end
package.preload["weread.lib.download_store"] = function() return Store end

local requests, fail_uid, archive_count, ordered, used_disk, prefixed = {}, nil, 0, {}, true, true
local image_failure, image_content_failure, source_status, source_error_kind, source_api_code
local archived_cover
local css_requests, annotation_writes = 0, 0
local source_options, annotation_source, raw_source_mode, annotation_failure, source_hook, finalize_hook, annotation_hook
local Content = {}
function Content.book_resolved_dir() return root end
function Content.fetch_single_chapter_source(client, current_settings, private_book, chapter, state)
    local id = tostring(chapter.chapterUid)
    client.last_request_error = nil
    requests[id] = (requests[id] or 0) + 1
    if source_status then
        client.last_request_error = { status = source_status, kind = source_error_kind, retryable = true }
        error("injected upstream status")
    end
    if source_api_code and id == "2" then
        client.last_request_error = { kind = "api_error", api_code = source_api_code, retryable = false }
        error("injected upstream API rejection")
    end
    if id == fail_uid then error("injected source failure") end
    source_options = state.source_options
    if not state.css then
        css_requests = css_requests + 1
        state.css = "p { margin: 0; }"
    end
    local text = '<html><body><p>Chapter ' .. id .. '</p><img src="../images/shared.jpg"/></body></html>'
    if raw_source_mode then
        private_book._content_format = "txt"
        state.raw_source = "Raw Chapter " .. id
    else state.raw_source = text end
    if source_hook then source_hook(current_settings, private_book, chapter) end
    return text
end
function Content.finalize_single_chapter_content(client, settings, _book, chapter, text, state)
    if finalize_hook then finalize_hook() end
    if not settings:get("cache").download_book_images then return text, {} end
    if image_failure == tostring(chapter.chapterUid) then
        client.last_request_error = { status = 404, retryable = false }
        state.resources_complete = false
        return text, {}
    end
    if image_content_failure == tostring(chapter.chapterUid) then
        state.resources_complete = false
        return text, {}
    end
    local path = state.workspace.asset_dir .. "/shared.jpg"
    write(path, "image bytes")
    return text, { { path = path, href = "images/shared.jpg", media_type = "image/jpeg", size = 11, store = true } }
end
function Content.cache_annotation_source(current_settings, _book, chapter, text, raw_text)
    annotation_writes = annotation_writes + 1
    annotation_source = { chapter_uid = tostring(chapter.chapterUid), text = text, raw_text = raw_text }
    if annotation_hook then annotation_hook(current_settings) end
    if annotation_failure then error("injected annotation persistence failure") end
end
local function check_body(chapter, source, assets)
    used_disk = used_disk and type(source) == "table" and type(source.path) == "string"
    local text = read(source.path)
    local id = tostring(chapter.chapterUid)
    assert(text:find("Chapter " .. id, 1, true))
    for _, asset in ipairs(assets) do
        prefixed = prefixed and asset.href == "images/" .. id .. "-shared.jpg"
        assert(text:find("../" .. asset.href, 1, true))
    end
end
function Content.save_book_epub(_settings, book, chapters, bodies, _suffix, assets, _css, cover, options)
    archive_count = archive_count + 1
    archived_cover = cover
    ordered = {}
    for _, chapter in ipairs(chapters) do
        ordered[#ordered + 1] = chapter.chapterUid
        local own = {}
        for _, asset in ipairs(assets) do
            if asset.href:find("images/" .. chapter.chapterUid .. "-", 1, true) == 1 then own[#own + 1] = asset end
        end
        check_body(chapter, bodies[tostring(chapter.chapterUid)], own)
    end
    options.check_cancelled()
    options.progress("archive", #chapters, #chapters)
    local path = book.cache_dir .. "/full.epub"; write(path, "complete book"); return path
end
function Content.save_chapter_epub(_settings, book, chapter, body, assets, _css, options)
    archive_count = archive_count + 1
    options.check_cancelled()
    check_body(chapter, body, assets)
    local path = book.cache_dir .. "/chapter-" .. chapter.chapterUid .. ".epub"
    write(path, "complete chapter"); return path
end
package.preload["weread.lib.content"] = function() return Content end
local Worker = require("weread.lib.book_download_worker")
local settings = { get = function(_self, key) return key == "cache" and { download_book_images = true } or {} end }
local scope = { marker = "original" }
local client = { set_request_context = function(_self, value) local old = scope; scope = value; return old end }
local cancelled, cancel_at, last_progress
local context = {
    cancelled = function() return cancelled end,
    checkCancelled = function() if cancelled then error("__weread_worker_cancelled__", 0) end end,
    emit = function(value)
        last_progress = clone(value)
        if cancel_at == value.index and value.stage == "source" then cancelled = true end
    end,
    sleep = function() end,
}
local chapters = { { chapterUid = 1, title = "Same" }, { chapterUid = 2, title = "Same" }, { chapterUid = 3, title = "End" } }
local book = { book_id = "synthetic", title = "Synthetic" }
local checks = 0
local function expect(value, label) checks = checks + 1; assert(value, label) end

fail_uid = "2"
local incomplete = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(not incomplete.path and #incomplete.failed_uids == 1, "incomplete full book must not publish")
expect(archive_count == 0 and requests["1"] == 1 and requests["3"] == 1, "successful chapters must be retained")
expect(requests["2"] == 3, "transient failure must have bounded retries")
expect(css_requests == 1, "a serial book job must reuse its shared stylesheet")
expect(scope.marker == "original" and store_closed == store_opened, "worker resources must be restored")
fail_uid = nil
local result = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(result.path and #result.failed_uids == 0, "resumed book must finish")
expect(requests["1"] == 1 and requests["2"] == 4 and requests["3"] == 1, "resume must fetch only missing chapter")
expect(archive_count == 1 and publication_count == 1, "whole book must be archived exactly once")
expect(table.concat(ordered, ",") == "1,2,3", "assembly must use catalog order")
expect(used_disk and prefixed, "assembly must use staged bodies and private resource hrefs")
local replay = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(replay.path == result.path and archive_count == 1 and requests["2"] == 4,
    "registration retry must reuse published output without download or archive")
local separate = Worker.run(settings, client, book, chapters, { suffix = "chapters", separate_chapters = true }, context)
expect(separate.chapter_paths["1"] ~= separate.chapter_paths["2"], "chapter outputs must remain distinct")
expect(requests["1"] == 1 and requests["2"] == 4, "output mode change must reuse chapter sources")

saved, publications = {}, {}
cancelled, cancel_at = false, 2
local ok, err = pcall(Worker.run, settings, client, book, chapters, { suffix = "full" }, context)
expect(not ok and tostring(err):find("__weread_worker_cancelled__", 1, true), "cancellation must escape acquisition retries")
expect(scope.marker == "original" and store_closed == store_opened, "cancellation must close store and restore scope")
expect(saved[Store:chapterKey(chapters[1], true)] ~= nil and saved[Store:chapterKey(chapters[2], true)] == nil
    and next(publications) == nil, "cancellation must preserve only already committed chapter bundles")

saved, publications, requests = {}, {}, {}
cancelled, cancel_at, image_failure = false, nil, "1"
local partial_images = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(partial_images.path and partial_images.resources_complete == false,
    "best-effort image failure must remain retryable without discarding readable text")
image_failure = nil
local repaired = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(repaired.resources_complete and requests["1"] == 2 and requests["2"] == 1 and requests["3"] == 1,
    "image recovery must retry only the affected chapter, not reuse an incomplete receipt")
saved, publications, requests = {}, {}, {}
image_content_failure = "2"
local malformed_image = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(malformed_image.resources_complete == false,
    "a failed image content check must remain retryable even without an HTTP diagnostic")
image_content_failure = nil
local valid_images = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(valid_images.resources_complete and requests["1"] == 1 and requests["2"] == 2 and requests["3"] == 1,
    "image content recovery must reuse every unaffected chapter")
saved, publications, requests = {}, {}, {}
source_status = 429
local limited = pcall(Worker.run, settings, client, book, chapters, { suffix = "full" }, context)
expect(not limited and requests["1"] == 1 and requests["2"] == nil,
    "rate limiting must pause the book without retrying or hammering later chapters")
saved, publications, requests = {}, {}, {}
source_status, last_progress = 503, nil
local unavailable, unavailable_error = pcall(Worker.run, settings, client, book, chapters,
    { suffix = "full" }, context)
expect(not unavailable and tostring(unavailable_error):find("injected upstream status", 1, true)
    and requests["1"] == 3 and requests["2"] == nil,
    "persistent HTTP 503 must pause after exactly three attempts while preserving the source error")
expect(last_progress and last_progress.stage == "paused" and last_progress.pause == true
    and last_progress.http_status == 503,
    "exhausted HTTP retries must emit pause metadata as the final progress update")
saved, publications, requests = {}, {}, {}
source_status, source_error_kind, last_progress = 401, "authentication", nil
local unauthenticated, authentication_error = pcall(Worker.run, settings, client, book, chapters,
    { suffix = "full" }, context)
expect(not unauthenticated and tostring(authentication_error):find("injected upstream status", 1, true)
    and requests["1"] == 1 and requests["2"] == nil,
    "authentication failure must preserve the source error and pause without retry")
expect(last_progress and last_progress.stage == "paused" and last_progress.pause == true
    and last_progress.http_status == 401 and last_progress.error_kind == "authentication",
    "authentication pause metadata must retain its HTTP status and error kind")
saved, publications, requests = {}, {}, {}
source_status, source_error_kind, source_api_code, last_progress = nil, nil, -10102, nil
local rejected = pcall(Worker.run, settings, client, book, chapters, { suffix = "full" }, context)
expect(not rejected and requests["1"] == 1 and requests["2"] == 1 and requests["3"] == nil,
    "API rejection -10102 must pause the book without skipping ahead or automatic retries")
expect(last_progress and last_progress.stage == "paused" and last_progress.pause == true
    and last_progress.error_kind == "api_error" and last_progress.api_code == -10102,
    "API pause metadata must retain the diagnostic kind and code")
source_api_code = nil
local resumed = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(resumed.path and requests["1"] == 1 and requests["2"] == 2 and requests["3"] == 1,
    "resuming after API rejection must reuse already committed chapters")

local function request_count()
    local total = 0
    for _, count in pairs(requests) do total = total + count end
    return total
end
local function carries_source(value)
    if type(value) ~= "table" then return false end
    for key, item in pairs(value) do
        if key == "assets" or key == "body" or key == "bundle" or key == "xhtml"
            or key == "raw_source" then return true end
        if carries_source(item) then return true end
    end
    return false
end
local function ready_options(prepared, job)
    return { key = job.key, ordinal = job.ordinal, css_path = prepared.css_path,
        content_format = prepared.content_format }
end

saved, publications, requests = {}, {}, {}
local phase_book = { book_id = "phases", title = "Phase book", metadata = { body = "large input payload" } }
local one_chapter = { chapters[1] }
local before_requests = request_count()
local prepared = Worker.prepare(settings, phase_book, one_chapter, { suffix = "full" }, context)
expect(request_count() == before_requests and #prepared.jobs == 1,
    "prepare must inventory chapters without fetching source content")
expect(prepared.jobs[1].ordinal == 1 and prepared.jobs[1].chapter_uid == "1"
    and prepared.jobs[1].key == Store:chapterKey(chapters[1], true) and not prepared.jobs[1].cached,
    "prepare must return ordered chapter identities and cache availability")
expect(not carries_source(prepared) and prepared.book.metadata == nil,
    "prepare must omit source payloads, asset lists, and nested book metadata")
expect(store_opened == store_closed, "prepare must release its database handle")

local opened_before, files_before = store_opened, files_opened
local writes_before, annotations_before = chapter_writes, annotation_writes
local ready = Worker.acquire(settings, client, prepared.book, chapters[1],
    ready_options(prepared, prepared.jobs[1]), context)
expect(ready.status == "ready" and ready.chapter_uid == "1" and ready.key == prepared.jobs[1].key,
    "acquire must return the requested chapter identity")
expect(store_opened == opened_before and files_opened == files_before + 1 and chapter_writes == writes_before,
    "acquire must use filesystem staging without opening or writing the database")
expect(files_opened == files_closed, "acquire must release the file workspace handle")
expect(annotation_writes == annotations_before and source_options and source_options.persist_source == false,
    "acquire must disable annotation source persistence")
expect(ready.annotation_path and read(ready.annotation_path):find('../images/shared.jpg', 1, true)
    and ready.annotation_raw_text == false,
    "acquire must stage original XHTML for the later annotation writer")
expect(not read(ready.annotation_path):find('../images/1-shared.jpg', 1, true)
    and read(ready.bundle.xhtml_path):find('../images/1-shared.jpg', 1, true),
    "annotation source must retain original image references before archive rewriting")
expect(scope.marker == "original", "acquire must restore the caller's request context")

local archives_before = archive_count
before_requests = request_count()
local uncommitted = Worker.assemble(settings, client, prepared.book, one_chapter, { suffix = "full" }, context)
expect(not uncommitted.path and uncommitted.failed_uids[1] == "1" and archive_count == archives_before,
    "assemble must reject an uncommitted chapter without publishing a partial full book")
expect(request_count() == before_requests and next(saved) == nil,
    "assemble must never fetch or commit missing chapter source")

local wrong_uid = clone(ready)
wrong_uid.chapter_uid = "999"
expect(not pcall(Worker.commit, settings, prepared.book, chapters[1], wrong_uid, context),
    "commit must reject a mismatched ready chapter UID")
local wrong_bundle_uid = clone(ready)
wrong_bundle_uid.bundle.chapter_uid = "999"
expect(not pcall(Worker.commit, settings, prepared.book, chapters[1], wrong_bundle_uid, context),
    "commit must reject a mismatched bundle chapter UID")
local wrong_key = clone(ready)
wrong_key.key = Store:chapterKey(chapters[2], true)
expect(not pcall(Worker.commit, settings, prepared.book, chapters[1], wrong_key, context),
    "commit must reject a different chapter cache key")
local text_settings = { get = function(_self, key)
    return key == "cache" and { download_book_images = false } or {}
end }
expect(not pcall(Worker.commit, text_settings, prepared.book, chapters[1], ready, context),
    "commit must recompute the cache key from the current image setting")
expect(chapter_writes == writes_before and annotation_writes == annotations_before,
    "identity validation must run before chapter and annotation writes")

ready.bundle.resources_complete = false
local committed = Worker.commit(settings, prepared.book, chapters[1], ready, context)
expect(chapter_writes == writes_before + 1 and annotation_writes == annotations_before + 1,
    "commit must persist the chapter and its annotation source")
expect(annotation_source.text == read(ready.annotation_path) and annotation_source.raw_text == false,
    "commit must pass original XHTML from the annotation file to the annotation writer")
expect(not carries_source(committed), "commit must return small metadata without chapter payloads")
chapter_reads = {}
before_requests = request_count()
local assembled = Worker.assemble(settings, client, prepared.book, one_chapter, { suffix = "full" }, context)
local allowed_incomplete = false
for _, entry in ipairs(chapter_reads) do
    allowed_incomplete = allowed_incomplete or (entry.key == ready.key and entry.allow_incomplete == true)
end
expect(assembled.path and assembled.resources_complete == false and allowed_incomplete,
    "assemble must explicitly read committed incomplete resources and preserve readable text")
expect(request_count() == before_requests, "assembling committed chapters must not issue source requests")

saved, publications, requests = {}, {}, {}
raw_source_mode = true
local raw_ready = Worker.acquire(settings, client, prepared.book, chapters[1],
    ready_options(prepared, prepared.jobs[1]), context)
expect(raw_ready.annotation_raw_text == true and read(raw_ready.annotation_path) == "Raw Chapter 1",
    "TXT acquisition must stage the original plain text with the raw-text marker")
annotation_failure = true
local raw_committed = Worker.commit(settings, prepared.book, chapters[1], raw_ready, context)
expect(raw_committed and saved[raw_ready.key] and annotation_source.text == "Raw Chapter 1"
    and annotation_source.raw_text == true, "annotation persistence failure must preserve a successful chapter commit")
annotation_failure, raw_source_mode = false, false
before_requests = request_count()
local cached_prepared = Worker.prepare(settings, prepared.book, one_chapter, { suffix = "full" }, context)
expect(cached_prepared.jobs[1].cached and not carries_source(cached_prepared)
    and request_count() == before_requests, "prepare must represent cached chapters without loading them into job metadata")

saved, publications, requests = {}, {}, {}
opened_before, writes_before, annotations_before = store_opened, chapter_writes, annotation_writes
source_status = 503
local transient = Worker.acquire(settings, client, prepared.book, chapters[1],
    ready_options(prepared, prepared.jobs[1]), context)
expect(transient.status == "failed" and transient.retryable and not transient.pause and requests["1"] == 1,
    "acquire must report transient failures after one source attempt")
source_status = 429
local paused = Worker.acquire(settings, client, prepared.book, chapters[1],
    ready_options(prepared, prepared.jobs[1]), context)
expect(paused.status == "failed" and paused.pause and requests["1"] == 2,
    "acquire must report rate limiting as a pause without retrying")
expect(store_opened == opened_before and chapter_writes == writes_before and annotation_writes == annotations_before,
    "failed acquisitions must not open or persist to either database")
source_status = nil
for _, stage in ipairs({ "source", "images" }) do
    local cancel = function() cancelled = true end
    if stage == "source" then source_hook = cancel else finalize_hook = cancel end
    before_requests = request_count()
    local stage_ok, stage_error = pcall(Worker.acquire, settings, client, prepared.book, chapters[1],
        ready_options(prepared, prepared.jobs[1]), context)
    expect(not stage_ok and tostring(stage_error):find("__weread_worker_cancelled__", 1, true)
        and request_count() == before_requests + 1,
        "cancellation after " .. stage .. " must escape acquisition without retry")
    expect(chapter_writes == writes_before and annotation_writes == annotations_before
        and scope.marker == "original" and files_opened == files_closed,
        "cancelled acquisition must release staging without persisting either database")
    source_hook, finalize_hook, cancelled = nil, nil, false
end
cancelled = true
local acquired_cancel, acquired_error = pcall(Worker.acquire, settings, client, prepared.book, chapters[1],
    ready_options(prepared, prepared.jobs[1]), context)
expect(not acquired_cancel and tostring(acquired_error):find("__weread_worker_cancelled__", 1, true),
    "acquire must throw cancellation instead of returning a retryable failure")
cancelled = false

saved, publications, requests = {}, {}, {}
local committed_full = Worker.run(settings, client, book, chapters, { suffix = "full" }, context)
expect(committed_full.path and #committed_full.selected_uids == 3,
    "exclusion fixture must start with a published book and three committed chapters")
before_requests, archives_before = request_count(), archive_count
local publications_before = publication_count
local excluded_full = Worker.assemble(settings, client, book, chapters,
    { suffix = "full", failed_uids = { 2 } }, context)
expect(not excluded_full.path and table.concat(excluded_full.selected_uids, ",") == "1,3"
    and table.concat(excluded_full.failed_uids, ",") == "2",
    "explicit failure must exclude a committed chapter and prevent a full-book result")
expect(archive_count == archives_before and publication_count == publications_before,
    "explicit failure must prevent reuse or replacement of an existing full publication")
local excluded_selected = Worker.assemble(settings, client, book, chapters,
    { suffix = "selected", failed_uids = { "2" } }, context)
expect(excluded_selected.path and table.concat(excluded_selected.selected_uids, ",") == "1,3"
    and table.concat(excluded_selected.failed_uids, ",") == "2" and table.concat(ordered, ",") == "1,3",
    "selected output must archive only successful chapters in catalog order")
expect(request_count() == before_requests and saved[Store:chapterKey(chapters[2], true)] ~= nil,
    "exclusion must neither acquire source content nor delete the previously committed chapter")

local cover_requests, cover_failures, cover_cancels = 0, 2, false
local cover_book = { book_id = "cover", title = "Cover book", cover = "https://images.test/cover.jpg" }
function client:get_binary(_url)
    cover_requests = cover_requests + 1
    if cover_cancels then error("__weread_worker_cancelled__", 0) end
    if cover_requests <= cover_failures then
        self.last_request_error = { status = 503, retryable = true }
        error("injected transient cover failure")
    end
    self.last_request_error = nil
    return "complete cover"
end
saved, publications, requests = {}, {}, {}
local recovered_cover = Worker.run(settings, client, cover_book, one_chapter, { suffix = "full" }, context)
expect(recovered_cover.path and recovered_cover.resources_complete and cover_requests == 3,
    "cover acquisition must recover from two transient failures on the third attempt")
expect(archived_cover == "complete cover" and requests["1"] == 1,
    "cover retry success must archive the fetched cover without repeating chapter acquisition")

saved, publications, requests = {}, {}, {}
cover_requests, cover_failures = 0, 3
local missing_cover = Worker.run(settings, client, cover_book, one_chapter, { suffix = "full" }, context)
expect(missing_cover.path and missing_cover.resources_complete == false and cover_requests == 3
    and archived_cover == nil, "exhausted cover retries must retain readable output with incomplete resources")
before_requests, archives_before = request_count(), archive_count
cover_failures = 0
local repaired_cover = Worker.run(settings, client, cover_book, one_chapter, { suffix = "full" }, context)
expect(repaired_cover.path and repaired_cover.path ~= missing_cover.path and repaired_cover.resources_complete
    and archived_cover == "complete cover" and cover_requests == 4 and archive_count == archives_before + 1,
    "resuming an incomplete cover must fetch it again and publish a new complete edition")
expect(request_count() == before_requests and requests["1"] == 1,
    "cover recovery must reuse every committed chapter source")
local cover_replay = Worker.run(settings, client, cover_book, one_chapter, { suffix = "full" }, context)
expect(cover_replay.path == repaired_cover.path and cover_requests == 4
    and archive_count == archives_before + 1 and request_count() == before_requests,
    "a repaired cover publication must replay without acquiring or assembling again")
saved, publications, requests = {}, {}, {}
cover_requests, cover_cancels = 0, true
archives_before, publications_before = archive_count, publication_count
local cover_cancelled, cover_cancel_error = pcall(Worker.run, settings, client, cover_book, one_chapter,
    { suffix = "full" }, context)
expect(not cover_cancelled and tostring(cover_cancel_error):find("__weread_worker_cancelled__", 1, true)
    and cover_requests == 1, "a cover cancellation marker must escape without retry even before the context flag changes")
expect(archive_count == archives_before and publication_count == publications_before
    and next(publications) == nil and saved[Store:chapterKey(chapters[1], true)] ~= nil,
    "cover cancellation must preserve committed source without archiving or publishing")
client.get_binary = nil

-- Serial acquisition nests one short auth scope inside a job-wide scope.
-- Every chapter must restore the same outer hook before its commit starts.
saved, publications, requests = {}, {}, {}
local auth_values = { cache = { download_book_images = false }, cookies = { session = "initial" },
    wr_ticket = "", wr_wrpa = "" }
local auth_updates, auth_flushes = 0, 0
local auth_settings = { get = function(_self, key, default)
    if auth_values[key] ~= nil then return auth_values[key] end
    return default
end }
function auth_settings:flush() auth_flushes = auth_flushes + 1 end
function auth_settings:update_auth(credentials, options)
    auth_updates = auth_updates + 1
    expect(options.flush == false, "nested auth capture did not suppress persistent settings flush")
    for key, value in pairs(credentials) do auth_values[key] = value end
end
local original_auth, original_flush = auth_settings.update_auth, auth_settings.flush
local outer_hook
source_hook = function(current_settings, _book, chapter)
    current_settings:update_auth({ cookies = { session = "body-" .. tostring(chapter.chapterUid) },
        wr_ticket = "body-ticket" }, { flush = true })
end
annotation_hook = function(current_settings)
    outer_hook = outer_hook or current_settings.update_auth
    expect(current_settings.update_auth == outer_hook and outer_hook ~= original_auth,
        "serial chapter acquisition accumulated auth hooks instead of restoring its outer scope")
end
local auth_chapters = {}
for index = 1, 24 do auth_chapters[index] = { chapterUid = 1000 + index, title = "Auth chapter" } end
local serial_auth = Worker.run(auth_settings, client, { book_id = "auth-book", title = "Auth book" },
    auth_chapters, { suffix = "full" }, context)
expect(auth_updates == #auth_chapters and auth_flushes == 0,
    "serial auth updates did not reach the original implementation exactly once per chapter")
expect(serial_auth.auth and serial_auth.auth.cookies.session == "body-1024"
    and serial_auth.auth.wr_ticket == "body-ticket", "serial result lost Cookie updates acquired before assembly")
expect(auth_settings.update_auth == original_auth and auth_settings.flush == original_flush,
    "successful serial job did not restore original settings hooks")
annotation_hook = nil
local independent = Worker.acquire(auth_settings, client, { book_id = "auth-book" }, auth_chapters[1],
    { key = Store:chapterKey(auth_chapters[1], false) }, context)
expect(independent.status == "ready" and independent.auth == nil,
    "independent acquisition returned credentials for another worker to merge")
expect(auth_settings.update_auth == original_auth and auth_settings.flush == original_flush
    and scope.marker == "original", "independent acquisition did not restore auth and request scopes")

local original_resolve = Content.book_resolved_dir
Content.book_resolved_dir = function() error("injected phase setup failure") end
for _, operation in ipairs({ "run", "assemble", "acquire" }) do
    local phase_ok, phase_result
    if operation == "acquire" then
        phase_ok, phase_result = pcall(Worker.acquire, auth_settings, client, book, auth_chapters[1],
            { key = Store:chapterKey(auth_chapters[1], false) }, context)
        expect(phase_ok and phase_result.status == "failed", "acquisition setup failure did not return a failed result")
    else
        phase_ok, phase_result = pcall(Worker[operation], auth_settings, client, book, auth_chapters,
            { suffix = "full" }, context)
        expect(not phase_ok and tostring(phase_result):find("injected phase setup failure", 1, true),
            operation .. " swallowed a phase setup failure")
    end
    expect(auth_settings.update_auth == original_auth and auth_settings.flush == original_flush
        and scope.marker == "original", operation .. " setup failure leaked auth or request scopes")
end
Content.book_resolved_dir = original_resolve
saved, publications, requests = {}, {}, {}
source_hook = function(current_settings)
    current_settings:update_auth({ cookies = { session = "cancelled-body" } }, { flush = true })
    cancelled = true
end
local serial_cancelled, serial_cancel_error = pcall(Worker.run, auth_settings, client, book, auth_chapters,
    { suffix = "full" }, context)
expect(not serial_cancelled and tostring(serial_cancel_error):find("__weread_worker_cancelled__", 1, true),
    "serial cancellation was swallowed by nested auth scopes")
expect(auth_settings.update_auth == original_auth and auth_settings.flush == original_flush
    and scope.marker == "original", "serial cancellation leaked inner or outer auth hooks")
source_hook, cancelled = nil, false
expect(store_opened == store_closed and files_opened == files_closed and scope.marker == "original",
    "all phase exits must close database handles and restore request context")
os.execute("rm -rf " .. string.format("%q", root))
print("book_download_worker_spec: " .. checks .. " checks")
