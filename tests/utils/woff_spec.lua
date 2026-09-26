--[[-- utils.woff 离线用例：WOFF 1.0 → sfnt 往返与错误路径。
@module tests.utils.woff_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local ffi = require("ffi")

-- 测试环境没有 ffi.loadlib；声明可能已被 ffi/zlib_h 定义过，重复声明失败无妨。
pcall(ffi.cdef, [[
unsigned long compressBound(unsigned long sourceLen);
int compress2(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen, int level);
int uncompress(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen);
]])
local libz = ffi.load("z")
local function compress(data)
    local n = libz.compressBound(#data)
    local buf = ffi.new("uint8_t[?]", n)
    local len = ffi.new("unsigned long[1]", n)
    assert(libz.compress2(buf, len, ffi.cast("const uint8_t *", data), #data, 9) == 0)
    return ffi.string(buf, len[0])
end
package.preload["ffi/zlib"] = function()
    return { zlib_uncompress = function(zdata, datalen)
        local buf = ffi.new("uint8_t[?]", datalen)
        local len = ffi.new("unsigned long[1]", datalen)
        assert(libz.uncompress(buf, len, ffi.cast("const uint8_t *", zdata), #zdata) == 0)
        return ffi.string(buf, len[0])
    end }
end

local Woff = require("utils.woff")

local function be32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end
local function be16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function pad4(n) return ("\0"):rep((4 - n % 4) % 4) end

-- 三张表：可压缩的大表、不可压缩的小表（WOFF 里存原文）、长度非 4 对齐的表
local tables = {
    { tag = "OS/2", data = "xyz", checksum = 7 },
    { tag = "glyf", data = ("glyph-data "):rep(500), checksum = 0x12345678 },
    { tag = "head", data = "\1\2\3\4\5\6\7\8", checksum = 0xFFFFFFFE },
}

local function sfnt()
    local out = { be32(0x00010000), be16(3), be16(32), be16(1), be16(16) }
    local offset = 12 + 16 * #tables
    for _, t in ipairs(tables) do
        out[#out + 1] = t.tag .. be32(t.checksum) .. be32(offset) .. be32(#t.data)
        offset = offset + #t.data + #pad4(#t.data)
    end
    for _, t in ipairs(tables) do out[#out + 1] = t.data .. pad4(#t.data) end
    return table.concat(out)
end

local function woff(corrupt)
    local dir, blobs = {}, {}
    local offset = 44 + 20 * #tables
    for _, t in ipairs(tables) do
        local z = compress(t.data)
        local stored = #z < #t.data and z or t.data
        if corrupt and t.tag == "glyf" then stored = stored:sub(1, 10) .. ("\0"):rep(#stored - 10) end
        dir[#dir + 1] = t.tag .. be32(offset) .. be32(#stored) .. be32(#t.data) .. be32(t.checksum)
        blobs[#blobs + 1] = stored .. pad4(#stored)
        offset = offset + #stored + #pad4(#stored)
    end
    local header = "wOFF" .. be32(0x00010000) .. be32(offset) .. be16(#tables) .. be16(0)
        .. be32(#sfnt()) .. be16(1) .. be16(0) .. ("\0"):rep(20)
    return header .. table.concat(dir) .. table.concat(blobs)
end

local dir = Config.dir() .. "/woff_spec"
os.execute('mkdir -p "' .. dir .. '"')
local function write(name, data)
    local path = dir .. "/" .. name
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
    return path
end
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- 往返：解包结果与原 sfnt 逐字节一致
local src = write("good.woff", woff())
local dest = dir .. "/good.ttf"
os.remove(dest)
local ok, err = Woff.toSfnt(src, dest)
Assert.is_true(ok)
Assert.is_nil(err)
Assert.eq(read(dest), sfnt())
Assert.is_nil(read(dest .. ".part"))

-- 非 WOFF 1.0（如 WOFF2）、截断目录、损坏的压缩表：返回错误且不留输出
local cases = {
    { "woff2.woff", "wOF2" .. ("\0"):rep(60) },
    { "short.woff", woff():sub(1, 60) },
    { "corrupt.woff", woff(true) },
}
for _, case in ipairs(cases) do
    local out = dir .. "/" .. case[1] .. ".ttf"
    os.remove(out)
    local bad_ok, bad_err = Woff.toSfnt(write(case[1], case[2]), out)
    Assert.is_nil(bad_ok, case[1])
    Assert.is_true(type(bad_err) == "string", case[1])
    Assert.is_nil(read(out), case[1])
    Assert.is_nil(read(out .. ".part"), case[1])
end

local missing_ok = Woff.toSfnt(dir .. "/missing.woff", dir .. "/missing.ttf")
Assert.is_nil(missing_ok)
