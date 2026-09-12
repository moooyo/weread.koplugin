-- Frozen 2943080 decoder for byte-for-byte differential regression tests.
local Crypto = require("weread.lib.crypto")
local Content = {}
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function checked_body(response_text)
    if not response_text or #response_text <= 32 then
        return ""
    end
    local expected = response_text:sub(1, 32)
    local body = response_text:sub(33)
    local actual = Crypto.md5_hex(body):upper()
    if actual ~= expected then
        error("Shard MD5 mismatch")
    end
    return body
end

local function base64_decode(data)
    data = data:gsub("-", "+"):gsub("_", "/")
    local pad = #data % 4
    if pad > 0 then
        data = data .. string.rep("=", 4 - pad)
    end
    data = data:gsub("[^" .. b64chars .. "=]", "")
    return (data:gsub(".", function(char)
        if char == "=" then
            return ""
        end
        local bits = ""
        local index = b64chars:find(char, 1, true) - 1
        for bit = 6, 1, -1 do
            bits = bits .. (index % 2 ^ bit - index % 2 ^ (bit - 1) > 0 and "1" or "0")
        end
        return bits
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(bits)
        if #bits ~= 8 then
            return ""
        end
        local byte = 0
        for i = 1, 8 do
            if bits:sub(i, i) == "1" then
                byte = byte + 2 ^ (8 - i)
            end
        end
        return string.char(byte)
    end))
end

local function swap_positions(encoded)
    local length = #encoded
    if length < 4 then
        return {}
    end
    if length < 11 then
        return {0, 2}
    end

    local n = math.min(4, math.floor((length + 9) / 10))
    local tmp = {}
    for i = length, length - n + 1, -1 do
        local byte = encoded:byte(i)
        local bin = {}
        repeat
            table.insert(bin, 1, tostring(byte % 2))
            byte = math.floor(byte / 2)
        until byte == 0
        local value = tonumber(table.concat(bin), 4) or 0
        table.insert(tmp, tostring(value))
    end
    tmp = table.concat(tmp)

    local result = {}
    local m = length - n - 2
    local step = #tostring(m)
    local i = 1
    while #result < 10 and i + step - 1 < #tmp do
        table.insert(result, (tonumber(tmp:sub(i, i + step - 1)) or 0) % m)
        local end2 = math.min(i + step, #tmp)
        if i + 1 <= #tmp then
            table.insert(result, (tonumber(tmp:sub(i + 1, end2)) or 0) % m)
        end
        i = i + step
    end
    return result
end

local function reverse_swaps(encoded, positions)
    local chars = {}
    for i = 1, #encoded do
        chars[i] = encoded:sub(i, i)
    end
    for i = #positions, 1, -2 do
        for k = 1, 0, -1 do
            local left = positions[i] + k + 1
            local right = positions[i - 1] + k + 1
            chars[left], chars[right] = chars[right], chars[left]
        end
    end
    return table.concat(chars)
end

local function decode_encoded_body(body)
    if #body == 0 then
        return ""
    end
    local encoded = body:sub(2)
    local restored = reverse_swaps(encoded, swap_positions(encoded))
    return base64_decode(restored)
end

function Content.decode_content_shards(e0, e1, e3)
    local body = checked_body(e0) .. checked_body(e1) .. checked_body(e3)
    return decode_encoded_body(body)
end

function Content.decode_content_shard(e0)
    return decode_encoded_body(checked_body(e0))
end


return {
    decode_content_shards = Content.decode_content_shards,
    decode_content_shard = Content.decode_content_shard,
    base64_decode = base64_decode,
    reverse_swaps = reverse_swaps,
    swap_positions = swap_positions,
}