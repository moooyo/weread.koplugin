-- Cache completion refreshes only the originating, still-visible book detail.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(value, message)
    checks = checks + 1
    assert(value, message)
end

local stack, detail_views, existing_paths, closed = {}, {}, {}, {}
local UIManager = {}
function UIManager:show(widget) stack[#stack + 1] = widget end
function UIManager:close(widget)
    if widget.onCloseWidget then widget:onCloseWidget() end
    closed[#closed + 1] = widget
    for index = #stack, 1, -1 do
        if stack[index] == widget then table.remove(stack, index) end
    end
end
function UIManager:getTopmostVisibleWidget() return stack[#stack] end
function UIManager:scheduleIn() error("Detail refresh must not wait until after the completion dialog") end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, options) options.kind = "confirm"; return options end }
end
for _, name in ipairs({
    "weread.ui.book_reviews_view", "ui/widget/inputdialog",
    "ui/widget/progressbardialog", "ui/widget/textviewer",
}) do package.preload[name] = function() return {} end end
package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.content"] = function()
    return { load_catalog_cache = function() error("The local catalog should remain available") end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index) return tostring(values[tonumber(index)]) end))
        end,
        log_error = tostring, display_error = tostring,
        file_exists = function(path) return existing_paths[path] == true end,
    }
end
package.preload["weread.ui.book_detail_view"] = function()
    return {
        show = function(data, callbacks)
            local view = { kind = "detail", data = data, callbacks = callbacks, close_count = 0 }
            function view:onCloseWidget() self.close_count = self.close_count + 1 end
            detail_views[#detail_views + 1] = view
            UIManager:show(view)
            return view
        end,
    }
end

local Library = require("weread.ui.library")
local function fixture()
    stack, detail_views, existing_paths, closed = {}, {}, {}, {}
    local chapters = {}
    for index = 1, 8 do chapters[index] = { chapterUid = index, title = "Chapter " .. index } end
    local book = { book_id = "42", title = "Fixture book", chapters = chapters }
    local books = { ["42"] = book }
    local host = {
        settings = { get = function(_, key, default) return key == "books" and books or default end },
        library_db = { getChapters = function() return chapters end },
        safeCallback = function(_, _label, callback) return callback end,
        getFullBookCachePath = function(_, value) return value.cached_full_book or value.cached_file end,
        bookRecordHasDownload = function(_, value)
            if existing_paths[value.cached_full_book] or existing_paths[value.cached_file] then return true end
            for _, path in pairs(value.cached_chapters or {}) do if existing_paths[path] then return true end end
            return false
        end,
        loadChapters = function(_, _book, callback) callback(chapters) end,
        showInfo = function() error("Unexpected information dialog") end,
    }
    host.ui = { openFile = function(_, path) host.opened = path end }
    host.downloader = { start = function(_, target, selected, suffix, options)
        host.job = { book = target, chapters = selected, suffix = suffix, options = options }
        return true
    end }
    for key, value in pairs(Library) do if host[key] == nil then host[key] = value end end
    local view = host:showBookMenu(book)
    local function confirm()
        local dialog = UIManager:getTopmostVisibleWidget()
        expect(dialog.kind == "confirm", "download confirmation was not shown")
        dialog.ok_callback()
        UIManager:close(dialog)
    end
    local function publish(full, count)
        local latest = { book_id = "42", title = "Fixture book", cached_chapters = {} }
        if full then
            latest.cached_full_book, latest.cached_file = "/cache/full.epub", "/cache/full.epub"
            existing_paths[latest.cached_full_book] = true
        else
            for index = 1, count do
                local path = "/cache/chapter-" .. index .. ".epub"
                latest.cached_chapters[tostring(index)], existing_paths[path] = path, true
            end
        end
        books["42"] = latest
        return latest
    end
    return host, book, view, confirm, publish
end

do
    local host, _, view, confirm, publish = fixture()
    expect(view.data.status_line == "Cached 0/8 chapters", "initial cache count was not empty")
    expect(view.data.bottom_actions[3].enabled == false, "initial reading action was not disabled")
    view.data.bottom_actions[1].callback()
    confirm()
    expect(host.job.suffix == "full" and #host.job.chapters == 8, "full-book selection changed")
    publish(true)
    host.job.options.on_complete(true, "/cache/full.epub")
    local refreshed = host._book_detail_view
    expect(refreshed ~= view and #detail_views == 2, "completion did not rebuild the current detail")
    expect(refreshed.data.status_line == "Cached 8/8 chapters", "completed full cache count stayed stale")
    expect(refreshed.data.bottom_actions[3].enabled == true, "completed full book remained unreadable")
    expect(view.close_count == 1, "refresh did not preserve the original close handler exactly once")
    local completion = { kind = "completion" }
    UIManager:show(completion)
    expect(UIManager:getTopmostVisibleWidget() == completion, "detail refresh covered the completion dialog")
    UIManager:close(completion)
    expect(UIManager:getTopmostVisibleWidget() == refreshed, "closing completion did not reveal updated detail")
    refreshed.data.bottom_actions[3].callback()
    expect(host.opened == "/cache/full.epub" and host._book_detail_view == nil,
        "refreshed reading action did not open the persisted full EPUB")
end

do
    local host, book, view, confirm, publish = fixture()
    local called, result_path = 0
    local original = function(ok, path)
        expect(ok, "success was not forwarded")
        called, result_path = called + 1, path
    end
    local options = { separate_chapters = true, on_complete = original }
    host:confirmAndDownloadChapters(book, { book.chapters[1], book.chapters[2] }, "chapters", options)
    confirm()
    publish(false, 2)
    host.job.options.on_complete(true, "/cache/chapter-1.epub")
    expect(called == 1 and result_path == "/cache/chapter-1.epub", "original completion callback changed")
    expect(options.on_complete == original and host.job.options ~= options, "caller options were mutated")
    expect(host.job.options.separate_chapters == true, "chapter output mode changed")
    expect(host._book_detail_view ~= view and host._book_detail_view.data.status_line == "Cached 2/8 chapters",
        "partial chapter count did not use the newly persisted record")
    expect(host._book_detail_view.data.bottom_actions[3].enabled, "partial cache did not enable reading")
end

for _, scenario in ipairs({ "closed", "replaced", "covered", "automatic_open", "callback_open", "failure" }) do
    local host, book, view, confirm, publish = fixture()
    local called = 0
    local options = {
        open_on_complete = scenario == "automatic_open",
        on_complete = function()
            called = called + 1
            if scenario == "callback_open" then host:openFile("/cache/full.epub") end
        end,
    }
    host:confirmAndDownloadChapters(book, book.chapters, "full", options)
    confirm()
    if scenario == "closed" then
        UIManager:close(view)
        expect(host._book_detail_view == nil, "closing detail retained its live view marker")
    elseif scenario == "replaced" then
        host:showBookMenu({ book_id = "other", title = "Other book", chapters = {} })
    elseif scenario == "covered" then
        UIManager:show({ kind = "another_page" })
    end
    local count_before = #detail_views
    local closes_before = #closed
    publish(true)
    host.job.options.on_complete(scenario ~= "failure", "/cache/full.epub")
    expect(called == 1, scenario .. ": original callback did not run exactly once")
    expect(#detail_views == count_before, scenario .. ": completion reopened or replaced another page")
    if scenario ~= "callback_open" then
        expect(#closed == closes_before, scenario .. ": completion closed a view after navigation")
    end
end

do
    local host, book, _, confirm, publish = fixture()
    local called, downloaded_path = 0
    host:downloadChapterAndRead(book, book.chapters[1], function(path)
        called, downloaded_path = called + 1, path
    end)
    confirm()
    publish(false, 1)
    host.job.options.on_complete(true, "/cache/chapter-1.epub")
    expect(host.job.options.single_chapter == true and host.job.suffix == "chapter", "single-chapter mode changed")
    expect(called == 1 and downloaded_path == "/cache/chapter-1.epub", "chapter reading callback changed")
    expect(host._book_detail_view.data.status_line == "Cached 1/8 chapters", "single-chapter completion stayed stale")
end

print("library_detail_download_spec: " .. checks .. " checks passed")
