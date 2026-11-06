--[[--
utils.inflate：raw / zlib / gzip 分块解压、截断容忍、坏流报错。

先把 ffi.load / loadlib 堵死，行为用例走纯 Lua。后面再测三层选择：
系统 so、KOReader loadlib、两边都没有 inflate 时的兜底。

@module tests.utils.inflate_spec
--]]

local Assert = require("support.assert")
local ffi = require("ffi")
local bit = require("bit")

local function unhex(h)
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

local TEXT = string.rep("月读 moon inflate spec ", 40)
local RAW = unhex("7b36a7e3c5fadd0ab9f9f9790a997969398925a90ac505a9c90acf462546254625868b0400")
local ZLIB = unhex("789c7b36a7e3c5fadd0ab9f9f9790a997969398925a90ac505a9c90acf462546254625868b040087babd88")
local GZIP = unhex("1f8b08000000000002ff7b36a7e3c5fadd0ab9f9f9790a997969398925a90ac505a9c90acf462546254625868b04000cb786a9e8030000")

local original_load, original_loadlib = ffi.load, ffi.loadlib
local Inflate
local function blocked(fn)
    ffi.load = function() error("ffi.load") end
    ffi.loadlib = function() error("ffi.loadlib") end
    local ok, err = pcall(fn)
    ffi.load, ffi.loadlib = original_load, original_loadlib
    if not ok then error(err, 0) end
end

blocked(function()
    package.loaded["utils.inflate"] = nil
    Inflate = require("utils.inflate")

    Assert.eq(Inflate.raw(RAW), TEXT)
    Assert.eq(Inflate.all(ZLIB, 15), TEXT)
    Assert.eq(Inflate.all(GZIP, 15 + 16), TEXT)
    Assert.eq(Inflate.all(GZIP, 15 + 32), TEXT, "15+32 自动识别 gzip")
    Assert.eq(Inflate.all(ZLIB, 15 + 32), TEXT, "15+32 自动识别 zlib")

    -- 分块：offset / len 只解中间那段，sink 收到的拼起来等于整串
    local wrapped = "xx" .. ZLIB .. "yy"
    local parts = {}
    local total = Inflate.stream(wrapped, 2, #ZLIB, 15, function(chunk) parts[#parts + 1] = chunk end)
    Assert.eq(total, #TEXT)
    Assert.eq(table.concat(parts), TEXT)

    -- 坏流 / 头不对：nil + err，不抛
    local out, err = Inflate.all(ZLIB, -15)
    Assert.is_nil(out)
    Assert.matches(err, "inflate failed")
    out, err = Inflate.raw("not deflate at all")
    Assert.is_nil(out)
    Assert.matches(err, "inflate failed")

    -- 截断：默认按失败算；partial 为真时把解出来的前段交出去
    local cut = ZLIB:sub(1, #ZLIB - 6)
    Assert.is_nil(Inflate.all(cut, 15))
    local head = Inflate.all(cut, 15, true)
    Assert.is_true(#head > 0 and #head <= #TEXT)
    Assert.eq(TEXT:sub(1, #head), head)

    -- 空输入连 partial 也失败；有字节但头不完整，partial 给出空串
    Assert.is_nil(Inflate.all("", -15, true))
    Assert.is_nil(Inflate.raw(""))
    Assert.eq(Inflate.all("\0", -15, true), "")
    Assert.is_nil(Inflate.all("\0", -15))

    -- 校验和错了，partial 也不能把坏数据当成成功。Lua 兜底的错误串和 so 的 -3 分开，免得选错层还假绿。
    local bad = ZLIB:sub(1, -2) .. string.char(bit.bxor(ZLIB:byte(-1), 0xff))
    out, err = Inflate.all(bad, 15)
    Assert.is_nil(out)
    Assert.matches(err, "inflate failed: data")
    Assert.is_nil(Inflate.all(bad, 15, true))

    -- stored 块：非末块 + 末块，跨过 64KB 输出块
    local function stored(payload, final)
        local n = #payload
        local nlen = bit.bxor(n, 0xFFFF)
        return string.char(final and 1 or 0, n % 256, math.floor(n / 256), nlen % 256, math.floor(nlen / 256))
            .. payload
    end
    Assert.eq(Inflate.raw("\1\0\0\255\255"), "")
    local a, b = string.rep("A", 40000), string.rep("B", 40000)
    local raw = stored(a, false) .. stored(b, true)
    local calls, got = 0, {}
    total = Inflate.stream(raw, 0, #raw, -15, function(chunk)
        calls = calls + 1
        Assert.is_true(#chunk <= 65536)
        got[#got + 1] = chunk
    end)
    Assert.eq(total, 80000)
    Assert.is_true(calls >= 2)
    Assert.eq(table.concat(got), a .. b)

    -- 流后面多出来的字节留着，不算失败
    local extra = "\120\1\1\0\0\255\255\0\0\0\1EXTRA"
    Assert.eq(Inflate.all(extra, 15), "")
end)

-- 和系统 zlib 的 compress2 对拍：动态哈夫曼、重复串、带文件名的 gzip
pcall(ffi.cdef, [[
unsigned long compressBound(unsigned long sourceLen);
int compress2(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen, int level);
unsigned long crc32(unsigned long crc, const uint8_t *buf, unsigned len);
]])
local z = ffi.load("z")
local function zcompress(src)
    local n = tonumber(z.compressBound(#src))
    local buf = ffi.new("uint8_t[?]", n)
    local outlen = ffi.new("unsigned long[1]", n)
    assert(z.compress2(buf, outlen, ffi.cast("const uint8_t *", src), #src, 9) == 0)
    return ffi.string(buf, outlen[0])
end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function gzip_crc(s)
    return tonumber(z.crc32(0, ffi.cast("const uint8_t *", s), #s))
end

local big = string.rep("月读", 30000)
Assert.eq(Inflate.all(zcompress(big), 15), big)
-- 末块预取会多吃几个字节；这条短流的尾刚好落在预取里，退回整字节之前会把校验和吃掉
local phrase = string.rep("月读 moon ", 50)
Assert.eq(Inflate.all(zcompress(phrase), 15), phrase)
local mixed = {}
for i = 0, 255 do mixed[#mixed + 1] = string.char(i) end
mixed = table.concat(mixed):rep(40) .. string.rep("abc", 2000)
Assert.eq(Inflate.all(zcompress(mixed), 15), mixed)
Assert.eq(Inflate.all(zcompress(mixed), 15 + 32), mixed)

local name = "chapter.txt"
local gz = "\31\139\8\8\0\0\0\0\0\255" .. name .. "\0" .. RAW
    .. le32(gzip_crc(TEXT)) .. le32(#TEXT)
Assert.eq(Inflate.all(gz, 15 + 16), TEXT)
Assert.eq(Inflate.all(gz, 15 + 32), TEXT)
local gz_extra = "\31\139\8\4\0\0\0\0\0\255\2\0\171\205" .. RAW
    .. le32(gzip_crc(TEXT)) .. le32(#TEXT)
Assert.eq(Inflate.all(gz_extra, 15 + 16), TEXT)

local function reload()
    package.loaded["utils.inflate"] = nil
    return require("utils.inflate")
end

local function with_loaders(load, loadlib, fn)
    ffi.load, ffi.loadlib = load, loadlib
    local ok, err = pcall(fn)
    ffi.load, ffi.loadlib = original_load, original_loadlib
    if not ok then error(err, 0) end
end

local function bad_zlib()
    return ZLIB:sub(1, -2) .. string.char(bit.bxor(ZLIB:byte(-1), 0xff))
end

-- 系统 so 能 inflate：不再问 KOReader。错误码是 zlib 的 -3，不是 Lua 的 data。
local so_names = {}
with_loaders(function(name)
    so_names[#so_names + 1] = name
    return original_load(name)
end, function()
    error("loadlib should not run")
end, function()
    local native = reload()
    Assert.eq(native.raw(RAW), TEXT)
    Assert.is_true(#so_names > 0)
    Assert.eq(native.all(GZIP, 15 + 16), TEXT)
    Assert.is_nil(native.all("", -15, true))
    local cut = ZLIB:sub(1, #ZLIB - 6)
    local head = native.all(cut, 15, true)
    Assert.eq(TEXT:sub(1, #head), head)
    local out, err = native.all(bad_zlib(), 15)
    Assert.is_nil(out)
    Assert.matches(err, "inflate failed: %-3")
end)

-- 系统 so 没有 inflate，用 KOReader 的 loadlib("z", 1)。
-- 不能走 ffi.load：这一层的 load 被换成了 libc，shim 再转回去会拿到没有 inflate 的库。
local ko = false
local versioned = ffi.os == "OSX" and "libz.1.dylib" or "libz.so.1"
with_loaders(function()
    return original_load("c")
end, function(name, version)
    Assert.eq(name, "z")
    Assert.eq(version, 1)
    ko = true
    return original_load(versioned)
end, function()
    local native = reload()
    Assert.eq(native.all(ZLIB, 15), TEXT)
    Assert.is_true(ko)
    Assert.eq(native.all(GZIP, 15 + 32), TEXT)
    local out, err = native.all(bad_zlib(), 15)
    Assert.is_nil(out)
    Assert.matches(err, "inflate failed: %-3")
end)

return true
