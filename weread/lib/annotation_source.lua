-- Preserve original HTML rune offsets without preserving tags, images or CSS.
-- WeRead heat-map ranges address the source HTML, not the rendered EPUB text.
local Source = {}
local INDEX_STRIDE = 256
local YIELD_STRIDE = 1024
-- Keep transient byte offsets out of the persisted array representation.
local span_indexes = setmetatable({}, { __mode = "k" })
local function length(byte)
    if byte < 128 then return 1 elseif byte < 224 then return 2
    elseif byte < 240 then return 3 else return 4 end
end

local function span_index(span)
    local index = span_indexes[span]
    if not index or index.text ~= span[3] then
        index = { text = span[3], runes = 0, next_byte = 1, in_entity = false,
            points = { { byte = 1, in_entity = false } } }
        span_indexes[span] = index
    end
    return index
end

local function extend_index(index, target, yield_fn)
    local steps = 0
    while index.runes < target and index.next_byte <= #index.text do
        local byte = index.text:byte(index.next_byte)
        if byte == 38 then index.in_entity = true
        elseif byte == 59 then index.in_entity = false end
        index.next_byte = index.next_byte + length(byte)
        index.runes = index.runes + 1
        if index.runes % INDEX_STRIDE == 0 then
            index.points[index.runes / INDEX_STRIDE + 1] = {
                byte = index.next_byte, in_entity = index.in_entity,
            }
        end
        steps = steps + 1
        if yield_fn and steps % YIELD_STRIDE == 0 then yield_fn() end
    end
end

local function byte_at(index, offset)
    offset = math.min(offset, index.runes)
    local block = math.floor(offset / INDEX_STRIDE)
    local point = index.points[block + 1]
    local byte_index, in_entity = point.byte, point.in_entity
    for _ = block * INDEX_STRIDE + 1, offset do
        local byte = index.text:byte(byte_index)
        if byte == 38 then in_entity = true
        elseif byte == 59 then in_entity = false end
        byte_index = byte_index + length(byte)
    end
    return byte_index, in_entity
end

function Source.plain(text, options)
    text = text:gsub("^\239\187\191", "")
    local span = { 0, 0, text, true }
    local index = span_index(span)
    extend_index(index, #text, options and options.yield)
    span[2] = index.runes
    return { span }
end

function Source.index(html, options)
    html = html:gsub("^\239\187\191", "")
    local spans, offset, i, start, pieces = {}, 0, 1, nil, {}
    local in_tag, quote, suppressed = false, nil, nil
    local tag = {}
    local function flush()
        if start then spans[#spans + 1] = { start, offset, table.concat(pieces) } end
        start, pieces = nil, {}
    end
    while i <= #html do
        local size = length(html:byte(i))
        local char = html:sub(i, i + size - 1)
        if in_tag then
            tag[#tag + 1] = char
            if quote then
                if char == quote then quote = nil end
            elseif char == '"' or char == "'" then quote = char
            elseif char == ">" then
                in_tag = false
                local name = table.concat(tag):lower()
                if name:match("^/?script[%s>]") or name:match("^/?style[%s>]") then
                    suppressed = name:sub(1, 1) ~= "/" or nil
                end
            end
        elseif char == "<" then
            flush()
            in_tag, tag = true, {}
        elseif not suppressed then
            start = start or offset
            pieces[#pieces + 1] = char
        end
        i, offset = i + size, offset + 1
        if options and options.yield and offset % YIELD_STRIDE == 0 then options.yield() end
    end
    flush()
    return spans
end

-- Source.index() and Source.plain() produce ordered, non-overlapping spans.
-- Locate the first possible overlap without scanning preceding chapter text.
local function first_span(spans, offset)
    local low, high = 1, #spans
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if spans[middle][2] <= offset then low = middle + 1
        else high = middle - 1 end
    end
    return low
end

-- The optional yield callback bounds initial indexing of a restored long span.
-- Later lookups reuse sparse rune offsets, including entity-boundary state.
function Source.quote(spans, range, options)
    local first, last = tostring(range):match("^(%d+)%-(%d+)$")
    first, last = tonumber(first), tonumber(last)
    if not first or not last or first >= last then return "" end
    spans = spans or {}
    local pieces = {}
    local yield_fn = options and options.yield
    local visited = 0
    for span_number = first_span(spans, first), #spans do
        local span = spans[span_number]
        if span[1] >= last then break end
        if span[1] < last and span[2] > first then
            local index = span_index(span)
            local start_offset = math.max(0, first - span[1])
            local end_offset = math.min(span[2] - span[1], last - span[1])
            extend_index(index, end_offset, yield_fn)
            local start_byte, starts_in_entity = byte_at(index, start_offset)
            local end_byte, ends_in_entity = byte_at(index, end_offset)
            if end_byte > start_byte then
                local text = span[3]:sub(start_byte, end_byte - 1)
                -- A cut entity cannot be interpreted safely.
                if span[4] then
                    pieces[#pieces + 1] = text
                else
                    if starts_in_entity or ends_in_entity then return "" end
                    pieces[#pieces + 1] = require("util").htmlEntitiesToUtf8(text)
                end
            end
        end
        visited = visited + 1
        if yield_fn and visited % INDEX_STRIDE == 0 then yield_fn() end
    end
    return table.concat(pieces)
end
return Source
