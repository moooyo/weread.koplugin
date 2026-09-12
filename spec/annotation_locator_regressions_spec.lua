package.path = "./?.lua;" .. package.path
local External = require("weread.lib.external_annotations")
local text, searches, positions, moves = "abcdef", 0, 0, 0
local function xp(value) return tonumber(value) end
local document = {
    getTextFromXPointers = function(_self, first, last) return text:sub(xp(first) + 1, xp(last)) end,
    getPrevVisibleChar = function(_self, point) return xp(point) > 0 and tostring(xp(point) - 1) or nil end,
    compareXPointers = function(_self, a, b)
        return xp(a) < xp(b) and 1 or xp(a) > xp(b) and -1 or 0
    end,
    getPosFromXPointer = function() positions = positions + 1; error("layout must not run") end,
    gotoXPointer = function() moves = moves + 1; error("reading position changed") end,
    findAllText = function(_self, quote)
        searches = searches + 1
        local found, init = {}, 1
        while true do
            local first, last = text:find(quote, init, true)
            if not first then break end
            found[#found + 1] = { start = tostring(first - 1), ["end"] = tostring(last) }
            init = first + 1
        end
        return found
    end,
}
local function locate(rows, options)
    options = options or {}
    options.chapter_ranges = options.chapter_ranges or { ["1"] = {
        start_xpointer = "0", end_xpointer = tostring(#text) } }
    return External.locate(document, { { book_id = "b", chapter_uid = "1", underlines = rows, reviews = {} } }, options)
end
local rows = {
    { range = "0-3", markText = "abc" }, { range = "2-5", markText = "cde" },
    { range = "3-6", markText = "def" },
}
local records, stats = locate(rows)
assert(#records == 3 and stats.located == 3, "overlapping or adjacent fast matches lost")
assert(searches == 0 and positions == 0 and moves == 0, "fast path used whole-book search, layout or navigation")

-- Generated footnote labels are visible in downloaded EPUBs but absent from
-- WeRead quotes. The fast path must ignore them while retaining the correct
-- document endpoints, and zero-width BOM characters must be removed from the
-- remote quotation.
text = "abc[36]def"
records = locate({ { range = "0-6", markText = "abc\239\187\191def" } })
assert(#records == 1 and records[1].pos0 == "0" and records[1].pos1 == "10",
    "generated footnote label broke quote matching or XPointer mapping")
assert(searches == 0, "footnote-normalized quote fell back to whole-book search")
text = "abcdef"

records = locate({ { range = "0-3", markText = "abc" }, { range = "0-6", markText = "abcdef" } })
assert(#records == 2 and records[1].pos0 == records[2].pos0, "equal-start underlines lost")
local previous = document.getPrevVisibleChar
document.getPrevVisibleChar = nil
records = locate(rows)
assert(#records == 3, "fallback rejected boundary, overlap or adjacency")
local original_search = document.findAllText
local search_allowed, search_yields = false, 0
document.findAllText = function(...)
    assert(search_allowed, "whole-book fallback searched again without yielding control")
    search_allowed = false
    return original_search(...)
end
records = locate(rows, { yield = function()
    search_allowed = true
    search_yields = search_yields + 1
end })
assert(#records == 3 and search_yields >= 3, "cooperative fallback changed its matches")
document.findAllText = original_search
-- A hit spanning the following chapter must not be accepted.
records = locate({ { range = "0-6", markText = "abcdef" } }, {
    chapter_ranges = { ["1"] = { start_xpointer = "0", end_xpointer = "3" } } })
assert(#records == 0, "fallback accepted a range crossing the chapter end")
document.getPrevVisibleChar = previous
-- Resume from the last saved matching batch, not from the first underline.
local chunks, many = {}, {}
for i = 1, 40 do
    local quote = string.format("L%02d", i)
    chunks[#chunks + 1] = quote
    many[#many + 1] = { range = (i * 4) .. "-" .. (i * 4 + 3), markText = quote }
end
text = table.concat(chunks, " ")
local checkpoint
local worker = coroutine.create(function()
    return locate(many, { checkpoint = function(state) checkpoint = state end,
        yield = function() coroutine.yield() end })
end)
assert(coroutine.resume(worker))
assert(checkpoint == nil, "endpoint prescan did not yield before processing the whole chapter")
for _ = 1, 100 do
    if checkpoint then break end
    local ok, err = coroutine.resume(worker)
    assert(ok, err)
end
assert(checkpoint and checkpoint.next_index == 17 and #checkpoint.records == 16)
records, stats = locate(many, { resume = checkpoint })
assert(#records == 40 and stats.located == 40 and stats.total == 40, "matching resume lost or duplicated records")

local batches = {}
records = locate(many, { include_items = false, incremental_checkpoint = true,
    checkpoint = function(state) batches[#batches + 1] = state end })
assert(#records == 40 and #batches == 3, "incremental matching did not finish every batch")
assert(#batches[1].records == 16 and #batches[2].records == 16 and #batches[3].records == 8,
    "incremental checkpoints repeated previously saved records")
assert(batches[1].stats.located == 16 and batches[2].stats.located == 32
    and batches[3].stats.located == 40, "checkpoint statistics were not stable cumulative snapshots")
assert(batches[1].next_index == 17 and batches[2].next_index == 33
    and batches[3].next_index == 41, "incremental checkpoints lost their input cursor")
assert(batches[2].records[1].id == records[17].id and batches[3].records[1].id == records[33].id,
    "incremental checkpoint record order changed")

local resume = {}
for key, value in pairs(batches[1]) do resume[key] = value end
resume.records = {}
for _, record in ipairs(batches[1].records) do resume.records[#resume.records + 1] = record end
local resumed_batches = {}
records, stats = locate(many, { resume = resume, include_items = false,
    incremental_checkpoint = true,
    checkpoint = function(state) resumed_batches[#resumed_batches + 1] = state end })
assert(#records == 40 and stats.located == 40 and stats.total == 40,
    "resuming incremental checkpoints lost or duplicated records")
assert(#resumed_batches == 2 and #resumed_batches[1].records == 16
    and #resumed_batches[2].records == 8, "resumed checkpoints re-emitted saved records")

local missing_rows = {}
for index = 1, 17 do missing_rows[index] = { range = index .. "-" .. (index + 1) } end
local empty_batches = {}
records = locate(missing_rows, { incremental_checkpoint = true,
    checkpoint = function(state) empty_batches[#empty_batches + 1] = state end })
assert(#records == 0 and #empty_batches == 2 and #empty_batches[1].records == 0,
    "a batch without matches lost its checkpoint")
assert(empty_batches[1].stats.missing_text == 16 and empty_batches[2].next_index == 18,
    "missing quotations did not advance incremental statistics and cursors")
print("annotation_locator_regressions_spec: bounds, matching resume and incremental checkpoints passed")
