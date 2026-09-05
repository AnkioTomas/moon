--[[-- 中文输入法配置与按键映射。
@module tests.ime.registry_spec
--]]

local Assert = require("support.assert")

local settings = { ime_layout = "pinyin" }
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, text) return text end })
end

local Registry = require("ime.registry")
local methods = Registry.list()
Assert.len(methods, 4)
Assert.eq(methods[1].id, "pinyin")
Assert.eq(methods[2].id, "wubi")
Assert.eq(methods[3].id, "cangjie")
Assert.eq(methods[4].id, "zhuyin")

local token, display = Registry.get("pinyin").mapKey("N")
Assert.eq(token, "n")
Assert.eq(display, "n")
local wubi = Registry.get("wubi")
Assert.eq(wubi.labels.q, "金勹儿")
Assert.eq(wubi.labels.m, "山贝冂")
Assert.is_true(wubi.show_codes)
token, display = wubi.mapKey("Q")
Assert.eq(token, "q")
Assert.eq(display, "q")
Assert.is_nil(wubi.mapKey("1"))

local cangjie = Registry.get("cangjie")
Assert.eq(cangjie.labels.a, "日")
Assert.is_nil(cangjie.labels.z)
Assert.is_true(cangjie.show_codes)
token, display = cangjie.mapKey("A")
Assert.eq(token, "a")
Assert.eq(display, "日")
Assert.is_nil(cangjie.mapKey("z"))

local zhuyin = Registry.get("zhuyin")
Assert.eq(zhuyin.labels.q, "ㄆ")
Assert.eq(zhuyin.labels["6"], "ˊ")
token, display = zhuyin.mapKey("Q")
Assert.eq(token, "ㄆ")
Assert.eq(display, "ㄆ")
token, display = zhuyin.mapKey(",")
Assert.eq(token, "ㄝ")
Assert.eq(display, "ㄝ")
Assert.is_nil(zhuyin.mapKey(" "))

settings.ime_layout = "zhuyin"
Assert.eq(Registry.current().id, "zhuyin")
settings.ime_layout = "broken"
Assert.eq(Registry.current().id, "pinyin")
