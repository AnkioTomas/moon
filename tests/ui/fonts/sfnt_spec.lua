--[[-- 缺空格字体的原子修复与 cmap/度量回归。
@module tests.ui.fonts.sfnt_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Sfnt = require("ui.fonts.sfnt")
local dir = Config.dir() .. "/sfnt_spec"
os.execute('mkdir -p "' .. dir .. '"')

local function be(n, len)
    local bytes = {}
    for i = len, 1, -1 do bytes[i], n = n % 256, math.floor(n / 256) end
    return string.char(unpack(bytes))
end

local function uint(s, p, len)
    local n = 0
    for i = p, p + len - 1 do n = n * 256 + s:byte(i) end
    return n
end

local function sum(s)
    s = s .. ("\0"):rep(-#s % 4)
    local n = 0
    for i = 1, #s, 4 do n = (n + uint(s, i, 4)) % 4294967296 end
    return n
end

local function cmap12(space)
    local groups = (space and be(32, 4) .. be(32, 4) .. be(1, 4) or "")
        .. be(65, 4) .. be(66, 4) .. be(1, 4)
    return be(12, 2) .. be(0, 2) .. be(16 + #groups, 4) .. be(0, 4)
        .. be(space and 2 or 1, 4) .. groups
end

local function cmap4(range)
    -- A/B → glyph 1/2，尾哨兵；range 分支覆盖 idRangeOffset 与 idDelta。
    return be(4, 2) .. be(range and 36 or 32, 2) .. be(0, 2)
        .. be(4, 2) .. be(4, 2) .. be(1, 2) .. be(0, 2)
        .. be(66, 2) .. be(65535, 2) .. be(0, 2)
        .. be(65, 2) .. be(65535, 2)
        .. be(range and 1 or 65472, 2) .. be(1, 2)
        .. be(range and 4 or 0, 2) .. be(0, 2)
        .. (range and be(0, 2) .. be(1, 2) or "")
end

local function font(format, short_loca, compressed_metrics, space)
    local cmap = format == 12 and cmap12(space) or cmap4(format == 5)
    local tables = {
        cmap = be(0, 2) .. be(1, 2) .. be(3, 2) .. be(format == 12 and 10 or 1, 2)
            .. be(12, 4) .. cmap,
        glyf = ("\0"):rep(12),
        head = ("\0"):rep(18) .. be(1000, 2) .. ("\0"):rep(30)
            .. be(short_loca and 0 or 1, 2) .. be(0, 2),
        hhea = ("\0"):rep(34) .. be(compressed_metrics and 1 or 3, 2),
        hmtx = compressed_metrics and be(500, 2) .. be(0, 2) .. be(2, 2) .. be(3, 2)
            or (be(500, 2) .. be(0, 2)):rep(3),
        loca = short_loca and be(0, 2) .. be(2, 2) .. be(4, 2) .. be(6, 2)
            or be(0, 4) .. be(4, 4) .. be(8, 4) .. be(12, 4),
        maxp = be(0x00010000, 4) .. be(3, 2) .. ("\0"):rep(26),
    }
    local names = { "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp" }
    local header = { be(0x00010000, 4), be(#names, 2), be(64, 2), be(2, 2), be(48, 2) }
    local data, offset = {}, 12 + #names * 16
    for _, tag in ipairs(names) do
        local s = tables[tag]
        header[#header + 1] = tag .. be(sum(s), 4) .. be(offset, 4) .. be(#s, 4)
        data[#data + 1] = s .. ("\0"):rep(-#s % 4)
        offset = offset + #s + -#s % 4
    end
    return table.concat(header) .. table.concat(data), tables
end

local function write(data)
    local path = dir .. "/font.ttf"
    local f = assert(io.open(path, "wb"))
    assert(f:write(data))
    assert(f:close())
    return path
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function tablesOf(data)
    local out = {}
    for i = 0, uint(data, 5, 2) - 1 do
        local p = 13 + i * 16
        local tag, offset, len = data:sub(p, p + 3), uint(data, p + 8, 4), uint(data, p + 12, 4)
        Assert.eq(offset % 4, 0)
        local s = data:sub(offset + 1, offset + len)
        if tag == "head" then s = s:sub(1, 8) .. ("\0"):rep(4) .. s:sub(13) end
        Assert.eq(sum(s), uint(data, p + 4, 4), tag .. " checksum")
        out[tag] = data:sub(offset + 1, offset + len)
    end
    return out
end

for _, format in ipairs({ 4, 5, 12 }) do
    for _, short in ipairs({ false, true }) do
        local original, before = font(format, short, true)
        local path = write(original)
        local changed, err = Sfnt.ensureSpace(path)
        Assert.is_true(changed)
        Assert.is_nil(err)
        local result = read(path)
        Assert.eq(sum(result), 0xB1B0AFBA, "whole-font checksum")
        local after = tablesOf(result)
        Assert.eq(after.glyf, before.glyf, "existing outlines unchanged")
        Assert.eq(uint(after.maxp, 5, 2), 4)
        Assert.eq(uint(after.hhea, 35, 2), 4)
        Assert.eq(#after.hmtx, 16)
        Assert.eq(after.hmtx:sub(5, 12), be(500, 2) .. be(2, 2) .. be(500, 2) .. be(3, 2))
        Assert.eq(after.hmtx:sub(13), be(250, 2) .. be(0, 2))
        local len = short and 2 or 4
        Assert.eq(#after.loca, 5 * len)
        Assert.eq(after.loca:sub(-len), before.loca:sub(-len), "new glyph is empty")
        local cmap = after.cmap
        local offset = uint(cmap, 9, 4) + 1
        Assert.eq(uint(cmap, offset, 2), 12)
        Assert.eq(uint(cmap, offset + 16, 4), 32)
        Assert.eq(uint(cmap, offset + 24, 4), 3, "space points to new glyph")
        -- format 4 的 range 测试故意让 A 映到 0，B 经 delta 映到 2。
        Assert.eq(uint(cmap, offset + 28, 4), format == 5 and 66 or 65)
        Assert.eq(uint(cmap, offset + 36, 4), format == 5 and 2 or 1)
        Assert.eq(Sfnt.ensureSpace(path), false, "repair is idempotent")
        Assert.eq(read(path), result)
        Assert.is_nil(read(path .. ".space.part"))
    end
end

local original = font(12, false, false, true)
local path = write(original)
Assert.eq(Sfnt.ensureSpace(path), false, "normal fonts untouched")
Assert.eq(read(path), original)

path = write(font(12, false, false))
Assert.is_true(Sfnt.ensureSpace(path), "uncompressed horizontal metrics")
local expanded = tablesOf(read(path))
Assert.eq(expanded.hmtx, (be(500, 2) .. be(0, 2)):rep(3) .. be(250, 2) .. be(0, 2))

for _, data in ipairs({ "wOF2" .. ("\0"):rep(20), "\0\1\0\0", font(12):sub(1, 200) }) do
    path = write(data)
    Sfnt.ensureSpace(path)
    Assert.eq(read(path), data, "unsupported/truncated input preserved")
    Assert.is_nil(read(path .. ".space.part"))

end

path = write(font(12))
local rename = os.rename
os.rename = function() return nil, "disk error" end
local ok, err = Sfnt.ensureSpace(path)
os.rename = rename
Assert.is_nil(ok)
Assert.eq(err, "disk error")
Assert.eq(read(path), font(12), "failed replacement preserves original")
Assert.is_nil(read(path .. ".space.part"))

local open = io.open
io.open = function(file, mode)
    if file == path .. ".space.part" then
        return {
            write = function() return nil, "disk full" end,
            close = function() return true end,
        }
    end
    return open(file, mode)
end
local written, write_err = Sfnt.ensureSpace(path)
io.open = open
Assert.is_nil(written)
Assert.matches(write_err, "disk full")
Assert.eq(read(path), font(12), "failed write preserves original")
