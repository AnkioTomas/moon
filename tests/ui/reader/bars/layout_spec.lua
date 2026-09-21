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
        get = function() return store end,
        saveSection = function() end,
    }
end
package.preload["ui.reader.bars.items"] = function()
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

package.loaded["ui.reader.bars.layout"] = nil
local Layout = require("ui.reader.bars.layout")

Assert.is_true(Layout.replace("top"))
Layout.setReplace("top", false)
Assert.is_false(Layout.replace("top"))

local top = Layout.get("top")
Assert.eq(top[1].id, "chapter")
Assert.eq(top[1].align, "left")
Assert.eq(top[2].id, "clock")
Assert.is_true(Layout.enabled("top", "clock"))
Assert.is_false(Layout.enabled("top", "percent"))

Layout.toggle("top", "percent")
Assert.is_true(Layout.enabled("top", "percent"))
local index, align = Layout.slot("top", "percent")
Assert.eq(index, 3)
Assert.eq(align, "right")

Layout.setAlign("top", "percent", "left")
Assert.eq(select(2, Layout.slot("top", "percent")), "left")

Layout.move("top", "percent", -1)
Assert.eq(Layout.get("top")[2].id, "percent")

Layout.toggle("top", "clock")
Assert.is_false(Layout.enabled("top", "clock"))

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
Assert.eq(fallback[1].id, "chapter")
Assert.eq(fallback[2].id, "clock")

return true
