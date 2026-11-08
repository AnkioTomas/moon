--[[--
盐选 VIP 3.1 签名：官网签名器的固定随机数对照向量。

@module tests.source.zhihu.sign_spec
--]]

local Assert = require("support.assert")
local original = math.random
math.random = function() return 0.5 end
local Sign = require("source.zhihu.sign")
math.random = original

local path = "/remix-web/paid_columns/1/sections/2/manuscript?v=1&manuscript_version=0"
local headers = Sign.headers(path)
Assert.eq(headers["x-zse-93"], "101_3_3.1")
Assert.eq(headers["x-zse-96"], "2.0_QQJWmQTduUEbH9LV=3hl9n0/3H=n0PdHAJOXWt5VL=gI/gwbiU03vEDdqKn0M/9l")
headers = Sign.headers(path, 'z_c0=fixture; d_c0="fixture-device|123"; _xsrf=other')
Assert.eq(headers["x-zse-96"], "2.0_uY57DBSvHsx=4A=28OOiDGh4IoXNtI6QgZpc+30xb=0Fu5Qp8CtbDtf6EYo+lNu8",
    "d_c0 引号不能剥掉，其他 Cookie 不参与签名")
headers = Sign.headers("/remix-web/paid_columns/1/sections/2/manuscript?manuscript_version=0&v=1",
    'd_c0="fixture-device|123"')
Assert.eq(headers["x-zse-96"], "2.0_w5tKPLmoSbv/CgSbnymseBni5iZTsax9RNmsXWg=h+fpC+1/M+I0aTR+eYJc0lb6",
    "查询串不能重排")
Assert.eq(Sign.headers(path, "other_d_c0=ignored")["x-zse-96"], Sign.headers(path)["x-zse-96"])

local Sha = require("ffi/sha2")
local original_md5 = Sha.md5
for _idx, fixture in ipairs({
    { random = 0, expected = "nZ=ktmDW5Au6W4bg9GDpq3NzqCmhx22uk5CuI+7cYMgnRJedTBkcbvUDVYwYdWQ5" },
    { random = 0.99999, expected = "b=7eGptEnaAJAWWEVqjX7+/+qlDbT/0EE6StfEggw1EieZBtJ6An+OX0=McttU86" },
}) do
    package.loaded["source.zhihu.sign"] = nil
    math.random = function() return fixture.random end
    Sha.md5 = function() return "4cf9d4f0069fc18fb3fcc0a50dceb852" end
    local variant = require("source.zhihu.sign")
    math.random, Sha.md5 = original, original_md5
    Assert.eq(variant.headers("/fixture")["x-zse-96"], "2.0_" .. fixture.expected)
end
