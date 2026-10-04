--[[--
ui.themes.widgets.sections：按实测高度装页、标题跟首行同页、一页时不画翻页条且内容顶对齐、翻页回调、页码夹取。

@module tests.ui.themes.widgets.sections_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Row = require("ui.themes.widgets.row")
local Sections = require("ui.themes.widgets.sections")

local tapped = {}
local function section(title, n)
    local rows = {}
    for i = 1, n do
        local name = title .. i
        rows[i] = function(width)
            return Row.widget({ width = width, title = name, callback = function() tapped[#tapped + 1] = name end })
        end
    end
    return { title = title, rows = rows }
end
local sections = { section("A", 3), section("B", 3) }

-- 一页装得下：没有翻页条，整块占满给定高度，首行紧贴分组标题（顶对齐，不居中）。
local one, page, pages = Sections.widget({ width = 600, height = 800, sections = sections, on_page = error })
Assert.eq(page, 1)
Assert.eq(pages, 1)
Assert.eq(one:getSize().h, 800)
for _, text in ipairs(Kit.texts(one)) do Assert.is_nil(text:find(" / ", 1, true), "一页时没有页码") end
one:paintTo(Kit.canvas(), 0, 0)
local rows = Kit.taps(one)
Assert.len(rows, 6)
-- paper：分组标题高 caption 11 + 上下 md 12 = 35。
Assert.eq(rows[1].dimen.y, 35)
rows[1]:onTapThemeArea()
Assert.eq(tapped[1], "A1")

-- paper 行高 48 + 1px 分割线。A 组 35 + 49×3 = 182；B 组标题块 12 间隔 + 35 + 49 = 96。
-- 300 高：整体 327 放不下，扣掉翻页条 40 后 B 的标题块也放不下 → B 连同首行挪到第 2 页。
local flipped
local first, p1, n1 = Sections.widget({
    width = 600, height = 300, sections = sections, on_page = function(p) flipped = p end,
})
Assert.eq(p1, 1)
Assert.eq(n1, 2)
Assert.eq(first:getSize().h, 300)
local texts = Kit.texts(first)
Assert.contains(texts, "A")
Assert.contains(texts, "A3")
Assert.contains(texts, "1 / 2")
Assert.is_false(texts[#texts] == "B", "标题不孤悬在页尾")
for _, text in ipairs(texts) do Assert.is_false(text == "B" or text == "B1", "B 组整体在第 2 页") end
local buttons = Kit.buttons(first)
buttons[#buttons]:onTapThemeButton()
Assert.eq(flipped, 2)

-- 页码越界夹到末页；第 2 页首块是 B 的标题块。
local second, p2 = Sections.widget({ width = 600, height = 300, sections = sections, page = 9, on_page = error })
Assert.eq(p2, 2)
texts = Kit.texts(second)
Assert.eq(texts[1], "B")
Assert.contains(texts, "B3")
Assert.contains(texts, "2 / 2")
