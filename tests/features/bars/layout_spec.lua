--[[--
阅读页栏布局：默认、清洗、开关、移动、对齐。
--]]

local Assert = require("support.assert")

local store = {
    book_reader_replace_top_bar = true,
    book_reader_replace_bottom_bar = true,
    book_reader_percent_decimals = false,
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

Assert.not_nil(Layout.slot("bottom", "percent"), "总进度组件保留原默认布局")
Assert.is_false(Layout.percentDecimals(), "两位小数默认关闭")
Layout.setPercentDecimals(true)
Assert.is_true(Layout.percentDecimals(), "用户可手动开启两位小数")
Layout.setPercentDecimals(false)
Assert.is_false(Layout.percentDecimals())

Layout.toggle("top", "percent")
Assert.not_nil(Layout.slot("top", "percent"))
local index, align = Layout.slot("top", "percent")
Assert.eq(index, 3)
Assert.eq(align, "right")

Layout.setAlign("top", "percent", "left")
Assert.eq(select(2, Layout.slot("top", "percent")), "left")
Layout.setAlign("top", "percent", "center")
Assert.eq(select(2, Layout.slot("top", "percent")), "center")
Layout.setAlign("top", "percent", "up")
Assert.eq(select(2, Layout.slot("top", "percent")), "center", "非法 align 不改")

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

store.book_reader_top_bar_layout = {
    { id = "chapter", align = "center" },
    { id = "clock", align = "right" },
}
Assert.eq(Layout.get("top")[1].align, "center", "清洗保留 center")

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

-- 顶栏边距：缺省 0，越界钳住；底栏边距读 KOReader 状态栏 container_bottom_padding，缺省 1。
Assert.eq(Layout.topMargin(), 0)
Layout.setTopMargin(100)
Assert.eq(Layout.topMargin(), 60)
Assert.eq(Layout.bottomMargin(nil), 1)
Assert.eq(Layout.bottomMargin({ container_bottom_padding = 20 }), 20)
Assert.eq(Layout.bottomMargin({ container_bottom_padding = 99 }), 49)

-- 进度条粗细：未设置跟随主题；越界钳到 1–24；nil 清除。
Assert.is_nil(Layout.progressThickness())
Layout.setProgressThickness(-3)
Assert.eq(Layout.progressThickness(), 1)
Layout.setProgressThickness(99)
Assert.eq(Layout.progressThickness(), 24)
Layout.setProgressThickness(6)
Assert.eq(Layout.progressThickness(), 6)
Layout.setProgressThickness(nil)
Assert.is_nil(Layout.progressThickness(), "清除后恢复跟随主题")

-- 双栏是显式设置：未写入或 false 时一律单栏，即使有居中项也不自动拆行。
Assert.is_false(Layout.stackedPreferred(), "旧配置缺省单栏")
Assert.is_false(Layout.stackedBottom({
    { id = "progress_bar", align = "left" },
    { id = "chapter", align = "center" },
}), "未开双栏时居中 + 进度条仍单栏")
Layout.setStacked(true)
Assert.is_true(store.book_reader_bottom_bar_stacked)
Assert.is_true(Layout.stackedPreferred())

-- 两行都有组件才是实际双栏；都在同一行则收成一行，不特判进度条或居中。
local both_up = {
    { id = "progress_bar", align = "left", row = "up" },
    { id = "percent", align = "right", row = "up" },
}
local split = {
    { id = "percent", align = "right", row = "up" },
    { id = "progress_bar", align = "left", row = "down" },
}
local text_split = {
    { id = "chapter", align = "left", row = "up" },
    { id = "percent", align = "right", row = "down" },
}
Assert.is_false(Layout.stackedBottom(both_up), "双栏但都在上行则收成一行")
Assert.is_true(Layout.stackedBottom(split), "上行有百分比、下行有进度条是两行")
Assert.is_true(Layout.stackedBottom(text_split), "两行都可以是普通文本组件")
Assert.is_false(Layout.stackedBottom({ { id = "percent", align = "right", row = "up" } }),
    "只有上行时不留空的下行")
Assert.is_false(Layout.stackedBottom({ { id = "progress_bar", align = "left", row = "down" } }),
    "只有下行时不留空的上行")

-- 旧双栏配置没有 row：迁一次，进度条下行、其它上行；已有 row 的不再改。
store.book_reader_bottom_bar_layout = {
    { id = "percent", align = "right" },
    { id = "progress_bar", align = "left" },
}
local migrated = Layout.get("bottom")
Assert.eq(Layout.itemRow(migrated[1]), "up")
Assert.eq(migrated[1].id, "percent")
Assert.eq(Layout.itemRow(migrated[2]), "down", "旧双栏把进度条迁到下行")
Assert.is_true(Layout.stackedBottom(migrated))
store.book_reader_bottom_bar_layout = {
    { id = "progress_bar", align = "left", row = "up" },
    { id = "percent", align = "right", row = "up" },
}
local kept = Layout.get("bottom")
Assert.eq(kept[1].row, "up", "已经写过行归属的进度条不强制下行")
Assert.eq(kept[2].row, "up")

store.book_reader_bottom_bar_layout = {
    { id = "percent", align = "right" },
    { id = "progress_bar", align = "left" },
}
Layout.setStacked(false)
Assert.eq(select(3, Layout.slot("bottom", "progress_bar")), "down", "旧布局的行归属不依赖开关")
Layout.setStacked(true)
Assert.is_true(Layout.stackedBottom(), "先读单栏再开双栏立即生效")
package.loaded["features.bars.layout"] = nil
Layout = require("features.bars.layout")
Assert.is_true(Layout.stackedBottom(), "重载后仍是同一布局")
Layout.setRow("bottom", "progress_bar", "up")
Layout.setStacked(false)
package.loaded["features.bars.layout"] = nil
Layout = require("features.bars.layout")
Layout.setStacked(true)
Assert.eq(select(3, Layout.slot("bottom", "progress_bar")), "up", "显式行归属在切换及重载后保留")
Assert.is_false(Layout.stackedBottom(), "明确放在同一行时不重新迁移")

Layout.setRow("bottom", "progress_bar", "down")
Assert.eq(select(3, Layout.slot("bottom", "progress_bar")), "down")
local pos, count, row = Layout.rowPosition("bottom", "percent")
Assert.eq(pos, 1)
Assert.eq(count, 1)
Assert.eq(row, "up")
Layout.setAlign("bottom", "progress_bar", "right")
Assert.eq(select(3, Layout.slot("bottom", "progress_bar")), "down", "改对齐不丢行归属")

store.book_reader_bottom_bar_layout = {
    { id = "chapter", align = "left", row = "up" },
    { id = "percent", align = "right", row = "down" },
    { id = "clock", align = "right", row = "up" },
}
Layout.moveInRow("bottom", "clock", -1)
local after = Layout.get("bottom")
Assert.eq(after[1].id, "clock", "上行内上移")
Assert.eq(after[2].id, "percent")
Assert.eq(after[3].id, "chapter")
Layout.moveInRow("bottom", "clock", -1)
Assert.eq(Layout.get("bottom")[1].id, "clock", "行首不能再上移到下行之外")

Layout.setStacked(false)
Assert.is_false(store.book_reader_bottom_bar_stacked)
Assert.is_false(Layout.stackedBottom(Layout.get("bottom")), "关回单栏后即使有上下行归属也画一行")
Assert.eq(select(3, Layout.slot("bottom", "percent")), "down", "切单栏不丢行归属")
store.book_reader_bottom_bar_stacked = nil
Assert.is_false(Layout.stackedPreferred(), "清掉键仍是单栏")

-- 设置列表顺序：已启用的按布局，其余按目录补齐；未知 id 丢掉但不丢后面的合法项。
store.book_reader_bottom_bar_layout = {
    { id = "percent", align = "right" },
    { id = "bogus", align = "left" },
    { id = "progress_bar", align = "left" },
}
local ordered = Layout.orderedCatalog("bottom")
Assert.eq(#ordered, 4)
Assert.eq(ordered[1].id, "percent")
Assert.eq(ordered[2].id, "progress_bar")
Assert.eq(ordered[3].id, "chapter")
Assert.eq(ordered[4].id, "clock")
store.book_reader_top_bar_layout = { { id = "clock", align = "center" } }
local top_ordered = Layout.orderedCatalog("top")
Assert.eq(top_ordered[1].id, "clock")
Assert.eq(top_ordered[2].id, "chapter")
Assert.eq(top_ordered[3].id, "percent")
Assert.is_nil((function()
    for i = 1, #top_ordered do
        if top_ordered[i].id == "progress_bar" then return true end
    end
end)(), "顶栏目录不含进度条")

return true
