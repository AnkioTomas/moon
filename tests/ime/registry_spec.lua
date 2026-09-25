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
Assert.len(methods, 5)
Assert.eq(methods[1].id, "pinyin")
Assert.eq(methods[2].id, "xiaohe")
Assert.eq(methods[3].id, "wubi")
Assert.eq(methods[4].id, "cangjie")
Assert.eq(methods[5].id, "zhuyin")
for _, method in ipairs(methods) do
    Assert.is_true(type(method.dictionary) == "string")
end

local xiaohe = Registry.get("xiaohe")
Assert.eq(xiaohe.dictionary, "pinyin")
Assert.eq(xiaohe.labels.v, "zh")
Assert.eq(xiaohe.labels.l, "iang")
Assert.is_nil(xiaohe.labels.a)
Assert.eq(xiaohe.mapKey("H"), "h")

-- 双拼查词先翻译成全拼再走拼音词库；其余方法原样透传。
local looked_up = {}
package.loaded["ime.pinyin.dictionary"] = nil
package.preload["ime.pinyin.dictionary"] = function()
    return {
        SYLLABLES = { "ni", "hao" },
        lookup = function(_, code)
            looked_up[#looked_up + 1] = code
            return { "你好" }
        end,
    }
end
Assert.eq(Registry.lookup(xiaohe, "nihc")[1], "你好")
Registry.lookup("pinyin", "nihao")
Assert.eq(looked_up[1], "nihao")
Assert.eq(looked_up[2], "nihao")

local token, display = Registry.get("pinyin").mapKey("N")
Assert.eq(token, "n")
Assert.eq(display, "n")
local wubi = Registry.get("wubi")
Assert.eq(wubi.labels.q, "金")
Assert.eq(wubi.labels.m, "山")
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
Assert.eq(display, "a")

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
