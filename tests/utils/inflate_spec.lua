--[[--
utils.inflate：raw / zlib / gzip 分块解压、截断容忍、坏流报错。

@module tests.utils.inflate_spec
--]]

local Assert = require("support.assert")
local Inflate = require("utils.inflate")

local function unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end
local TEXT = string.rep("月读 moon inflate spec ", 40)
local RAW = unhex("7b36a7e3c5fadd0ab9f9f9790a997969398925a90ac505a9c90acf462546254625868b0400")
local ZLIB = unhex("789c7b36a7e3c5fadd0ab9f9f9790a997969398925a90ac505a9c90acf462546254625868b040087babd88")
local GZIP = unhex("1f8b08000000000002ff7b36a7e3c5fadd0ab9f9f9790a997969398925a90ac505a9c90acf462546254625868b04000cb786a9e8030000")

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

return true
