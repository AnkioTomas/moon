--[[--
ui.themes.widgets.button / pager / tabbar / row / titlebar：变体、禁用、选中态与点击分流。

@module tests.ui.themes.widgets.button_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Button = require("ui.themes.widgets.button")
local Pager = require("ui.themes.widgets.pager")
local Row = require("ui.themes.widgets.row")
local Tabbar = require("ui.themes.widgets.tabbar")
local TitleBar = require("ui.themes.widgets.titlebar")

-- 按钮：宽按内容加内边距，高取 control.height；normal 描黑边。
local hits = 0
local btn = Button:new{ text = "确定", callback = function() hits = hits + 1 end }
local box = btn[1]
Assert.eq(btn:getSize().h, 40)
Assert.eq(box.box_w, #"确定" * 5 + 24)
Assert.eq(box.style.border, 1)
Assert.eq(box.style.border_color, 0x00)
Assert.is_true(btn:onTapThemeButton())
Assert.eq(hits, 1)

-- 禁用：边框改 disabled，点按吞掉不回调。
local off = Button:new{ text = "确定", enabled = false, callback = function() hits = hits + 1 end }
Assert.eq(off[1].style.border_color, 0xAA)
Assert.eq(off[1][1].fgcolor, 0xAA)
Assert.is_true(off:onTapThemeButton())
Assert.eq(hits, 1)

-- ghost：无底无边；primary：实心反色。
local ghost = Button:new{ icon = "close", variant = "ghost" }
Assert.eq(ghost[1].style.border, 0)
Assert.is_nil(ghost[1].style.bg)
local primary = Button:new{ text = "OK", variant = "primary", width = 120 }
Assert.eq(primary[1].style.bg, 0x00)
Assert.eq(primary[1][1].fgcolor, 0xFF)
Assert.eq(primary:getSize().w, 120)

-- 翻页条：到头一侧置灰。
local pager = Pager.widget({ width = 300, page = 1, pages = 3 })
local nav = Kit.buttons(pager)
Assert.is_false(nav[1].enabled)
Assert.is_true(nav[2].enabled)
Assert.contains(Kit.texts(pager), "1 / 3")
pager = Pager.widget({ width = 300, page = 3, pages = 3, dots = true })
nav = Kit.buttons(pager)
Assert.is_true(nav[1].enabled)
Assert.is_false(nav[2].enabled)
local dots = Kit.find(pager, function(w) return w.style ~= nil and w.box_w == 8 end)
Assert.len(dots, 3)
Assert.eq(dots[3].style.bg, 0x00, "当前页圆点 ink")
Assert.eq(dots[1].style.bg, 0xAA)
-- title 代替页码，置灰规则不变。
pager = Pager.widget({ width = 300, page = 2, pages = 3, title = "今日总览" })
Assert.contains(Kit.texts(pager), "今日总览")
for _, s in ipairs(Kit.texts(pager)) do Assert.is_true(s ~= "2 / 3") end
nav = Kit.buttons(pager)
Assert.is_true(nav[1].enabled and nav[2].enabled)
nav = Kit.buttons(Pager.widget({ width = 300, title = "2026年9月" }))
Assert.is_true(nav[1].enabled and nav[2].enabled, "无界翻页两侧常亮")
pager = Pager.widget({ width = 300, page = 1, pages = 2, dots = true, center = Button:new{ text = "完成" } })
Assert.contains(Kit.texts(pager), "完成")
Assert.len(Kit.buttons(pager), 3, "center 代替圆点")

-- 底栏：两格都吞点按；当前格不回调，其余回调 id；paper 画底部指示条。
local picked
local tabs = { { id = "home", text = "首页", icon = "home" }, { id = "shelf", text = "书架", icon = "book" } }
local bar = Tabbar.widget({ width = 200, tabs = tabs, active = "home", on_tab = function(id) picked = id end })
local cells = Kit.taps(bar)
Assert.len(cells, 2)
Assert.is_true(cells[1]:onTapThemeArea())
Assert.is_nil(picked, "当前格不回调")
cells[2]:onTapThemeArea()
Assert.eq(picked, "shelf")
Assert.eq(bar:getSize().h, 56)

-- bold：选中格整块反色、无指示条。
Kit.use("bold")
bar = Tabbar.widget({ width = 200, tabs = tabs, active = "home", on_tab = function() end })
local active_box = Kit.find(bar, function(w) return w.style ~= nil and w.style.bg == 0x00 end)
Assert.len(active_box, 1)
local inks = Kit.find(active_box[1], function(w) return w.fgcolor ~= nil end)
Assert.len(inks, 2, "图标 + 文字")
for _, w in ipairs(inks) do Assert.eq(w.fgcolor, 0xFF, "选中格图标文字反白: " .. w.text) end

-- 行：选中反色、副文字跟主文字同色；禁用不可点；bold 画 2px 分割线。
local row = Row.widget({ width = 300, title = "字体", subtitle = "当前", selected = true, callback = function() end })
Assert.eq(#Kit.taps(row), 1)
Assert.eq(Kit.find(row, function(w) return w.style ~= nil end)[1].style.bg, 0x00)
local fg = {}
for _, w in ipairs(Kit.find(row, function(w) return w.text ~= nil and w.fgcolor ~= nil end)) do fg[w.text] = w.fgcolor end
Assert.eq(fg["字体"], 0xFF)
Assert.eq(fg["当前"], 0xFF)
Assert.eq(row:getSize().h, Row.height(true) + 2)
local disabled = Row.widget({ width = 300, title = "x", enabled = false, callback = function() end })
Assert.len(Kit.taps(disabled), 0)

-- 开关行：toggle 给出「开/关」状态，有 callback 也不画箭头。
local function chevrons(w)
    return #Kit.find(w, function(c) return c.text == "chevron_right" end)
end
Assert.eq(chevrons(Row.widget({ width = 300, title = "x", callback = function() end })), 1)
local on = Row.widget({ width = 300, title = "x", toggle = true, callback = function() end })
Assert.contains(Kit.texts(on), "开")
Assert.eq(chevrons(on), 0)
Assert.contains(Kit.texts(Row.widget({ width = 300, title = "x", toggle = false })), "关")

-- soft：row.divider=0 不画线，标题栏也没有线。
Kit.use("soft")
local plain = Row.widget({ width = 300, title = "x" })
Assert.eq(plain:getSize().h, 48)
Assert.eq(#plain, 1)
local title = TitleBar.widget({ width = 300, title = "设置", right_icon = "close" })
Assert.eq(#title, 1)
Assert.eq(title:getSize().h, TitleBar.height())
Assert.len(Kit.buttons(title), 1)

return true
