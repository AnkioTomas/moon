--[[--
features.ime.pinyin.ko_lookup：KOReader zh_pinyin_data → 候选条词表。

不碰 900KB 真表；注入小码表验证精确命中、前缀收集、上限与非法码。

@module tests.features.ime.pinyin.ko_lookup_spec
--]]

local Assert = require("support.assert")

package.preload["features.ime.table_dictionary"] = function()
    return { MAX_CANDIDATES = 3 }
end

package.loaded["features.ime.pinyin.ko_lookup"] = nil
package.loaded["features.ime.table_dictionary"] = nil
local Ko = require("features.ime.pinyin.ko_lookup")

Ko.reset({
    a = { "啊", "阿" },
    an = "安",
    ang = { "昂", "盎" },
    ni = { "你", "尼", "呢", "泥" },
    nihao = "你好",
    nihong = { "霓虹" },
})

Assert.is_true(Ko.isAvailable())
Assert.eq(Ko.lookup("an")[1], "安")
Assert.eq(Ko.lookup("nihao")[1], "你好")
Assert.eq(Ko.lookup("ni")[1], "你")
Assert.eq(Ko.lookup("ni")[3], "呢")
Assert.eq(#Ko.lookup("ni"), 3, "不得超过 MAX_CANDIDATES")

local prefix = Ko.lookup("nih")
Assert.eq(prefix[1], "你好", "前缀先扫到 nihao")
Assert.eq(prefix[2], "霓虹")

Assert.len(Ko.lookup("zzz"), 0)
Assert.len(Ko.lookup("NI"), 0)
Assert.len(Ko.lookup(""), 0)

Ko.reset(nil)
Assert.is_false(Ko.isAvailable(), "清空后不可用（未再 dofile）")
Assert.len(Ko.lookup("ni"), 0)
