-- Small, real stored ZIP fixtures for archive-wrapper and footer tests.
local M = {}
local bit = require("bit")
local function integer(value, width)
    local bytes = {}
    for index = 1, width do
        bytes[index] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return table.concat(bytes)
end
local function crc32(value)
    local crc = -1
    for index = 1, #value do
        crc = bit.bxor(crc, value:byte(index))
        for _ = 1, 8 do
            crc = bit.bxor(bit.rshift(crc, 1), bit.band(crc, 1) == 1 and 0xedb88320 or 0)
        end
    end
    return bit.bnot(crc) % 4294967296
end
function M.write(path, members, options)
    options = options or {}
    local file = assert(io.open(path, "wb"))
    local names, central, offset = {}, {}, 0
    for name in pairs(members) do names[#names + 1] = name end
    table.sort(names, function(a, b)
        if a == "mimetype" then return b ~= "mimetype" end
        if b == "mimetype" then return false end
        return a < b
    end)
    for _, name in ipairs(names) do
        local data = name == "mimetype" and "application/epub+zip" or ""
        local crc = crc32(data)
        local local_header = "PK\003\004" .. integer(20, 2) .. integer(0, 8)
            .. integer(crc, 4) .. integer(#data, 4) .. integer(#data, 4)
            .. integer(#name, 2) .. integer(0, 2) .. name
        assert(file:write(local_header, data))
        central[#central + 1] = "PK\001\002" .. integer(20, 2) .. integer(20, 2)
            .. integer(0, 8) .. integer(crc, 4) .. integer(#data, 4) .. integer(#data, 4)
            .. integer(#name, 2) .. integer(0, 12) .. integer(offset, 4) .. name
        offset = offset + #local_header + #data
    end
    local directory = table.concat(central)
    assert(file:write(directory))
    if options.zip64 then
        assert(file:write("PK\006\006", integer(44, 8), integer(45, 2), integer(45, 2),
            integer(0, 8), integer(#names, 8), integer(#names, 8),
            integer(#directory, 8), integer(offset, 8)))
        assert(file:write("PK\006\007", integer(0, 4), integer(offset + #directory, 8), integer(1, 4)))
    end
    if not options.omit_end then
        assert(file:write("PK\005\006", integer(0, 4),
            integer(options.zip64 and 65535 or #names, 2), integer(options.zip64 and 65535 or #names, 2),
            integer(options.zip64 and 4294967295 or #directory, 4),
            integer(options.zip64 and 4294967295 or offset, 4), integer(0, 2)))
    end
    assert(file:close())
end
return M
