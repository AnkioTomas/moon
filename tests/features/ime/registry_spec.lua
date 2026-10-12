--[[-- 中文输入法配置与按键映射。
@module tests.features.ime.registry_spec
--]]

local Assert = require("support.assert")

local settings = { ime_layout = "pinyin" }
package.preload["utils.settings"] = function()
    return { get = function(name) assert(name == "features.ime"); return settings end }
end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, text) return text end })
end

local Registry = require("features.ime.registry")
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
package.loaded["features.ime.pinyin.dictionary"] = nil
package.preload["features.ime.pinyin.dictionary"] = function()
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

Assert.eq(Registry.get("pinyin").mapKey("N"), "n")
local wubi = Registry.get("wubi")
Assert.eq(wubi.labels.q, "金")
Assert.eq(wubi.labels.m, "山")
Assert.is_true(wubi.show_codes)
Assert.eq(wubi.mapKey("Q"), "q")
Assert.is_nil(wubi.mapKey("1"))

local cangjie = Registry.get("cangjie")
Assert.eq(cangjie.labels.a, "日")
Assert.is_nil(cangjie.labels.z)
Assert.is_true(cangjie.show_codes)
Assert.eq(cangjie.mapKey("A"), "a")

local zhuyin = Registry.get("zhuyin")
Assert.eq(zhuyin.labels.q, "ㄆ")
Assert.eq(zhuyin.labels["6"], "ˊ")
Assert.eq(zhuyin.mapKey("Q"), "ㄆ")
Assert.eq(zhuyin.mapKey(","), "ㄝ")
Assert.is_nil(zhuyin.mapKey(" "))

settings.ime_layout = "zhuyin"
Assert.eq(Registry.current().id, "zhuyin")
settings.ime_layout = "broken"
Assert.eq(Registry.current().id, "pinyin")
