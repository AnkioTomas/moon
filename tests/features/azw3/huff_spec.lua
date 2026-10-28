--[[-- features.azw3.huff：对照 Calibre 解压《努力的意义》首条文本记录 --]]

local Assert = require("support.assert")
local Huff = require("features.azw3.huff")

local root = "tests/fixtures/azw3_huff"

local function read(name)
    local f = assert(io.open(root .. "/" .. name, "rb"))
    local data = f:read("*a")
    f:close()
    return data
end

Assert.errors(function() Huff.reader({}) end, "HUFF")
Assert.errors(function() Huff.reader({ "not-huff" }) end, "HUFF")
Assert.errors(function()
    Huff.reader({ read("huff.bin"), "not-cdic" })
end, "CDIC")

local unpack = Huff.reader({ read("huff.bin"), read("cdic1.bin"), read("cdic2.bin") })
local plain = unpack(read("record1.bin"))
Assert.eq(plain, read("record1.out"))
Assert.eq(plain:sub(1, 5), "<?xml")

return true
