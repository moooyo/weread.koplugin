package.path = "./?.lua;" .. package.path
package.preload["util"] = function()
    return { htmlEntitiesToUtf8 = function(text) return text:gsub("&amp;", "&") end }
end
local Source = require("weread.lib.annotation_source")
local spans = Source.index("\239\187\191<p>甲乙<b>丙</b>&amp;丁</p>")
assert(Source.quote(spans, "3-5") == "甲乙", "rune offsets must not become UTF-8 byte offsets")
assert(Source.quote(spans, "4-9") == "乙丙", "quote failed across tags")
assert(Source.quote(spans, "13-19") == "&丁", "entity did not decode")
assert(Source.quote(spans, "13-15") == "", "partial entity was accepted")
assert(Source.quote(spans, "15-18") == "", "range starting inside an entity was accepted")
assert(Source.quote(Source.plain("甲<&乙"), "1-3") == "<&", "raw TXT offsets were interpreted as HTML")
local scripted = Source.index('<script>x</script><p>abc</p>')
assert(#scripted == 1 and scripted[1][3] == "abc", "script text entered quote source")

local function rune_slice(text, first, last)
    local offsets, byte_index = {}, 1
    while byte_index <= #text do
        offsets[#offsets + 1] = byte_index
        local byte = text:byte(byte_index)
        byte_index = byte_index + (byte < 128 and 1 or byte < 224 and 2 or byte < 240 and 3 or 4)
    end
    offsets[#offsets + 1] = #text + 1
    return text:sub(offsets[first + 1], offsets[last + 1] - 1)
end

-- A decoded database row has no process-local sparse index yet.
local long_text = string.rep("A\228\184\173B", 4096)
local restored = { { 0, 12288, long_text, true } }
local yields = 0
local options = { yield = function() yields = yields + 1 end }
assert(Source.quote(restored, "12280-12288", options) == rune_slice(long_text, 12280, 12288),
    "a distant TXT quotation returned incorrect UTF-8 boundaries")
assert(yields > 0, "initial long-span indexing did not yield")
local first_yields = yields
for _, bounds in ipairs({ { 0, 3 }, { 254, 259 }, { 4095, 4100 }, { 12280, 12288 } }) do
    assert(Source.quote(restored, bounds[1] .. "-" .. bounds[2], options)
        == rune_slice(long_text, bounds[1], bounds[2]), "cached out-of-order TXT quotation changed")
end
assert(yields == first_yields, "cached TXT quotations rescanned the long prefix")
for key in pairs(restored) do assert(key == 1, "transient index polluted the persisted span array") end
for key in pairs(restored[1]) do
    assert(type(key) == "number" and key >= 1 and key <= 4,
        "transient index polluted a persisted source span")
end
restored[1][3] = string.rep("Z", 12288)
assert(Source.quote(restored, "12280-12288") == "ZZZZZZZZ", "changed span text reused stale byte offsets")

local entity_text = string.rep("a", 255) .. "&amp;" .. string.rep("b", 300)
local entity_spans = { { 0, #entity_text, entity_text } }
assert(Source.quote(entity_spans, "255-260") == "&", "entity crossing an index boundary was not decoded")
assert(Source.quote(entity_spans, "257-260") == "", "cached entity state accepted an interior start")
assert(Source.quote(entity_spans, "254-259") == "", "cached entity state accepted an interior end")
assert(Source.quote(entity_spans, "260-263") == "bbb", "closed entity state leaked into following text")

local distant_spans = {}
for index = 1, 2000 do distant_spans[index] = { index * 10, index * 10 + 3, "abc" } end
assert(Source.quote(distant_spans, "19999-20003") == "abc", "binary span lookup skipped the final overlap")
assert(Source.quote(distant_spans, "19993-20000") == "", "binary span lookup included a tag gap")
assert(Source.quote(distant_spans, "19991-20002") == "bcab", "binary span lookup changed cross-span concatenation")
local indexing_yields = 0
local indexed = Source.index("<p>" .. string.rep("a", 4096) .. "</p>", {
    yield = function() indexing_yields = indexing_yields + 1 end,
})
assert(indexing_yields > 0 and Source.quote(indexed, "3-6") == "aaa",
    "cooperative HTML indexing changed source offsets")
print("annotation_source_spec: sparse UTF-8 lookup, entity boundaries and cooperative indexing passed")
