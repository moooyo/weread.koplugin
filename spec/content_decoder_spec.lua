package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
local Content = require("weread.lib.content")
local Crypto = require("weread.lib.crypto")
local Legacy = require("spec.helpers.legacy_content_decoder")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end
local function upvalue(fn, wanted)
    for index = 1, 100 do
        local name, value = debug.getupvalue(fn, index)
        if not name then break end
        if name == wanted then return value end
    end
    error("missing decoder helper: " .. wanted)
end
local decode_body = upvalue(Content.decode_content_shard, "decode_encoded_body")
local decode_base64 = upvalue(decode_body, "base64_decode")
local reverse_swaps = upvalue(decode_body, "reverse_swaps")
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function encode_base64(data)
    local parts = {}
    for index = 1, #data, 3 do
        local a, b, c = data:byte(index, index + 2)
        local value = a * 65536 + (b or 0) * 256 + (c or 0)
        local a64 = math.floor(value / 262144) % 64 + 1
        local b64 = math.floor(value / 4096) % 64 + 1
        local c64 = math.floor(value / 64) % 64 + 1
        local d64 = value % 64 + 1
        parts[#parts + 1] = alphabet:sub(a64, a64) .. alphabet:sub(b64, b64)
            .. (b and alphabet:sub(c64, c64) or "=") .. (c and alphabet:sub(d64, d64) or "=")
    end
    return table.concat(parts)
end
local function forward_swaps(encoded)
    local positions = Legacy.swap_positions(encoded)
    local bytes = {}
    for index = 1, #encoded do bytes[index] = encoded:sub(index, index) end
    for index = 2, #positions, 2 do
        for delta = 0, 1 do
            local left, right = positions[index] + delta + 1, positions[index - 1] + delta + 1
            bytes[left], bytes[right] = bytes[right], bytes[left]
        end
    end
    return table.concat(bytes)
end
local function shard(body) return Crypto.md5_hex(body):upper() .. body end
local function compare_payload(encoded, expected)
    local body = "0" .. forward_swaps(encoded)
    local split_a, split_b = math.floor(#body / 3), math.floor(#body * 2 / 3)
    local e0 = shard(body:sub(1, split_a))
    local e1 = shard(body:sub(split_a + 1, split_b))
    local e3 = shard(body:sub(split_b + 1))
    local previous = Legacy.decode_content_shards(e0, e1, e3)
    local current = Content.decode_content_shards(e0, e1, e3)
    expect(current == previous, "content shard decoding changed")
    expect(current == expected, "content shard output did not preserve the expected bytes")
    expect(Content.decode_content_shard(shard(body)) == previous, "single shard decoding diverged")
end

for _, encoded in ipairs({ "", "=", "===", "A", "AA", "AAA", "AAAA", "AAAAA",
    "Zg==", "Zm8=", "Zm9v", "Z=g==", "Zg==AAAA", "A=A=A=A",
    "-___", "+///", "A\0A\255A\nA", " Z m\r9\nv\t== ", "!?@#", "Q", "Q!", "QQ!" }) do
    local expected = Legacy.base64_decode(encoded)
    expect(decode_base64(encoded) == expected, "Base64 filtering or incomplete-tail behavior changed")
    compare_payload(encoded, expected)
end
expect(Content.decode_content_shards(nil, "", "short") == "", "empty shard handling changed")
expect(Content.decode_content_shard(string.rep("0", 32)) == "", "empty checksum body handling changed")
local ok, err = pcall(Content.decode_content_shard, string.rep("0", 32) .. "0AAAA")
expect(not ok and tostring(err):find("Shard MD5 mismatch", 1, true), "invalid shard checksum was accepted")

math.randomseed(20260912)
local function random_bytes(size)
    local bytes, chunks, count = {}, {}, 0
    for _ = 1, size do
        count = count + 1
        bytes[count] = string.char(math.random(0, 255))
        if count == 4096 then chunks[#chunks + 1] = table.concat(bytes); count = 0 end
    end
    if count > 0 then chunks[#chunks + 1] = table.concat(bytes, "", 1, count) end
    return table.concat(chunks)
end
for _, size in ipairs({ 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 15, 16, 31, 32, 63, 64,
    127, 128, 255, 256, 1023, 4096, 16384, 65536, 262144, 1048576 }) do
    local data = random_bytes(size)
    local encoded = encode_base64(data)
    if size % 2 == 1 then encoded = encoded:gsub("=", ""):gsub("%+", "-"):gsub("/", "_") end
    compare_payload(encoded, data)
    collectgarbage("collect")
end
for _, data in ipairs({ "\239\187\191BOM", "\228\184\173\240\159\152\128",
    "\192\128\237\160\128\244\144\128\128", "\255\0\254\128" }) do
    compare_payload(encode_base64(data), data)
end

for _, positions in ipairs({ {}, { 0, 2 }, { 0, 0 }, { 0, 1 }, { 0, 2, 1, 3 },
    { 1, 1, 1, 1 }, { 0, 1, 1, 2, 2, 3, 3, 4, 4, 5 } }) do
    local encoded = "0123456789abcdef"
    expect(reverse_swaps(encoded, positions) == Legacy.reverse_swaps(encoded, positions),
        "overlapping sparse swaps changed their reversal order")
end
for index = 1, 128 do
    local encoded = random_bytes(32 + index)
    local positions = {}
    for position = 1, 10 do positions[position] = math.random(0, #encoded - 2) end
    expect(reverse_swaps(encoded, positions) == Legacy.reverse_swaps(encoded, positions),
        "random sparse swap sequence diverged")
end

for _, fixture in ipairs(require("spec.fixtures.content_decoder_cases")) do
    local expected = fixture.expected_hex:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end)
    expect(Content.decode_content_shards(fixture.e0, fixture.e1, fixture.e3) == expected,
        "Python reference content fixture failed: " .. fixture.name)
    expect(Content.decode_content_shard(fixture.single) == expected,
        "Python reference style fixture failed: " .. fixture.name)
end

local function measure(fn, ...)
    collectgarbage("collect")
    local baseline = collectgarbage("count")
    local original_concat, original_gsub = table.concat, string.gsub
    local largest_table, largest_substitution = 0, 0
    rawset(table, "concat", function(values, ...)
        largest_table = math.max(largest_table, #values)
        return original_concat(values, ...)
    end)
    rawset(string, "gsub", function(...)
        local value, count = original_gsub(...)
        largest_substitution = math.max(largest_substitution, #value)
        return value, count
    end)
    collectgarbage("stop")
    local started = os.clock()
    local success, value = pcall(fn, ...)
    local elapsed = os.clock() - started
    local allocated = collectgarbage("count") - baseline
    collectgarbage("restart")
    rawset(table, "concat", original_concat)
    rawset(string, "gsub", original_gsub)
    if not success then error(value) end
    return value, { table_slots = largest_table, substitution_bytes = largest_substitution,
        allocated_kb = allocated, seconds = elapsed }
end
local large = encode_base64(random_bytes(768 * 1024))
-- Keep the result interned before both measurements, so identical-output
-- string reuse does not favor whichever decoder happens to run second.
local expected_base64 = decode_base64(large)
local previous, old_metrics = measure(Legacy.base64_decode, large)
local current, new_metrics = measure(decode_base64, large)
expect(previous == current and current == expected_base64, "large Base64 comparison changed output")
expect(old_metrics.substitution_bytes == #large * 6 and new_metrics.substitution_bytes == 0,
    "Base64 decoding still expanded the input into a bit string")
expect(new_metrics.table_slots <= 4096 and new_metrics.allocated_kb < old_metrics.allocated_kb,
    "Base64 decoding did not bound its byte buffer and reduce transient allocation")
print(string.format("content_decoder_spec: base64 old_alloc_kb=%.1f new_alloc_kb=%.1f old_seconds=%.3f new_seconds=%.3f",
    old_metrics.allocated_kb, new_metrics.allocated_kb, old_metrics.seconds, new_metrics.seconds))
local positions = { 0, 1, 1, 2, 100, 101, #large - 3, 2, 5, 6 }
local expected_swaps = Legacy.reverse_swaps(large, positions)
previous, old_metrics = measure(Legacy.reverse_swaps, large, positions)
current, new_metrics = measure(reverse_swaps, large, positions)
expect(previous == current and current == expected_swaps, "large sparse swap comparison changed output")
expect(old_metrics.table_slots == #large and new_metrics.table_slots <= 41,
    "swap reversal retained a payload-sized character table")
expect(new_metrics.allocated_kb < old_metrics.allocated_kb, "sparse swaps did not reduce transient allocation")
print(string.format("content_decoder_spec: swaps old_alloc_kb=%.1f new_alloc_kb=%.1f old_seconds=%.3f new_seconds=%.3f",
    old_metrics.allocated_kb, new_metrics.allocated_kb, old_metrics.seconds, new_metrics.seconds))
print(("content_decoder_spec: %d checks"):format(checks))
