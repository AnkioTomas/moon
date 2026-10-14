--[[--
阅读页栏布局：默认、清洗、开关、移动、对齐。
--]]

local Assert = require("support.assert")

local store = {
    book_reader_replace_top_bar = true,
    book_reader_replace_bottom_bar = true,
    book_reader_top_bar_layout = {
        { id = "chapter", align = "left" },
        { id = "clock", align = "right" },
    },
    book_reader_bottom_bar_layout = {
        { id = "progress_bar", align = "left" },
        { id = "percent", align = "right" },
    },
}

package.preload["utils.settings"] = function()
    return {
        get = function(name) assert(name == "features.bars"); return store end,
        save = function(name) assert(name == "features.bars") end,
    }
end
package.preload["features.bars.items"] = function()
    return {
        catalog = function(which)
            local all = {
                { id = "chapter", top = true, bottom = true },
                { id = "clock", top = true, bottom = true },
                { id = "percent", top = true, bottom = true },
                { id = "progress_bar", bottom = true },
            }
            local out = {}
            for i = 1, #all do
                if all[i][which] then
                    out[#out + 1] = all[i]
                end
            end
            return out
        end,
    }
end

package.loaded["features.bars.layout"] = nil
local Layout = require("features.bars.layout")

Assert.is_true(Layout.replace("top"))
Layout.setReplace("top", false)
Assert.is_false(Layout.replace("top"))

local top = Layout.get("top")
Assert.eq(top[1].id, "chapter")
Assert.eq(top[1].align, "left")
Assert.eq(top[2].id, "clock")
Assert.not_nil(Layout.slot("top", "clock"))
Assert.is_nil(Layout.slot("top", "percent"))

Layout.toggle("top", "percent")
Assert.not_nil(Layout.slot("top", "percent"))
local index, align = Layout.slot("top", "percent")
Assert.eq(index, 3)
Assert.eq(align, "right")

Layout.setAlign("top", "percent", "left")
Assert.eq(select(2, Layout.slot("top", "percent")), "left")

Layout.move("top", "percent", -1)
Assert.eq(Layout.get("top")[2].id, "percent")

-- 设为第几位：一次跨多位是取出再插入，越界截断到首尾
local before = Layout.get("top")
Layout.move("top", before[1].id, 99)
local after = Layout.get("top")
Assert.eq(after[#after].id, before[1].id)
Assert.eq(after[1].id, before[2].id, "其余项整体前移，不是首尾互换")
Layout.move("top", before[1].id, -99)
Assert.eq(Layout.get("top")[1].id, before[1].id)

Layout.toggle("top", "clock")
Assert.is_nil(Layout.slot("top", "clock"))

store.book_reader_top_bar_layout = {
    { id = "nope", align = "left" },
    { id = "chapter", align = "up" },
    { id = "chapter", align = "right" },
}
local cleaned = Layout.get("top")
Assert.eq(#cleaned, 1)
Assert.eq(cleaned[1].id, "chapter")
Assert.eq(cleaned[1].align, "left")

store.book_reader_top_bar_layout = {}
local fallback = Layout.get("top")
Assert.eq(#fallback, 0)

-- 文字大小：底栏以 KOReader 状态栏为准；顶栏未设置跟随底栏；越界钳到范围内。
Assert.eq(Layout.fontSize("bottom", nil), 14)
Assert.eq(Layout.fontSize("bottom", { text_font_size = 18 }), 18)
Assert.eq(Layout.fontSize("top", { text_font_size = 18 }), 18)
Assert.is_false(Layout.topFontCustom())
Layout.setFontSize("top", 99)
Assert.eq(Layout.fontSize("top", { text_font_size = 18 }), 36)
Assert.is_true(Layout.topFontCustom())
Layout.setFontSize("top", nil)
Assert.is_false(Layout.topFontCustom())
Layout.setFontSize("bottom", 20)
Assert.eq(Layout.fontSize("bottom", nil), 20)
Assert.eq(Layout.fontSize("bottom", { text_font_size = 16 }), 16)

-- 顶栏高度：缺省 12 保持原行为；越界钳到范围内。
Assert.eq(Layout.topHeight(), 12)
Layout.setTopHeight(-5)
Assert.eq(Layout.topHeight(), 0)
Layout.setTopHeight(24)
Assert.eq(Layout.topHeight(), 24)

return true
