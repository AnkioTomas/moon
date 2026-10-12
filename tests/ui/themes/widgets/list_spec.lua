--[[--
ui.themes.widgets.list / text_viewer：分页、翻到当前项、单选关窗、多选就地翻转、换项夹页、正文翻页。

@module tests.ui.themes.widgets.list_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local List = require("ui.themes.widgets.list")
local TextViewer = require("ui.themes.widgets.text_viewer")

local function items(n, checked_at)
    local out = {}
    for i = 1, n do
        out[i] = { text = "项" .. i, value = i, checked = checked_at and i == checked_at or nil }
    end
    return out
end

-- paper：行距 48 + 1px 分割线；800 高减标题栏 57 与翻页条 40 → 每页 14 项。
local picked
local list = List:new{ title = "排序", items = items(30, 20), on_select = function(v) picked = v end }
Assert.eq(list.per_page, 14)
Assert.eq(list:pages(), 3)
Assert.eq(list.page, 2, "翻到 checked 项所在页")
Assert.is_false(list.mask, "全屏列表不画遮罩")
local rows = Kit.taps(list)
Assert.len(rows, 14)
Assert.contains(Kit.texts(list), "2 / 3")
-- 第 20 项在第 2 页第 6 行，按选中样式画、radio 选中。
local marks = Kit.find(list, function(w) return w.text == "radio_button_checked" end)
Assert.len(marks, 1)
local selected = Kit.find(list, function(w) return w.style ~= nil and w.style.bg == 0xFF and w.box_w == 600 end)
Assert.is_true(#selected >= 1)
-- 满屏：面板正好是整屏。
Assert.eq(list[1]:getSize().h, 800)

-- 单选：关窗后回调。
rows[1]:onTapThemeArea()
Assert.eq(Kit.closed[#Kit.closed], list)
Assert.eq(picked, 15)

-- 翻页夹到范围内；换成更少的项时停在末页。
list = List:new{ items = items(30) }
Assert.eq(list.page, 1)
list:goPage(99)
Assert.eq(list.page, 3)
list:goPage(0)
Assert.eq(list.page, 1)
list:goPage(3)
list:setItems(items(5))
Assert.eq(list.page, 1)
Assert.len(Kit.taps(list), 5)
Assert.len(Kit.find(list, function(w) return w.icon == "chevron_left" end), 0, "单页不画翻页条")
Assert.len(Kit.find(list, function(w)
    return type(w.text) == "string" and (w.text:match("^radio") or w.text:match("^check_box")) ~= nil
end), 0, "checked 为 nil 不画标记")

-- 多选：点按就地翻转、不关窗、回调 on_toggle；标记换成 checkbox。
local toggled
local multi = { { text = "a", value = "a", checked = false }, { text = "b", value = "b", checked = true } }
list = List:new{ items = multi, multi = true, on_toggle = function(v, c) toggled = { v, c } end }
local closed = #Kit.closed
Kit.taps(list)[1]:onTapThemeArea()
Assert.is_true(multi[1].checked)
Assert.eq(toggled[1], "a")
Assert.is_true(toggled[2])
Assert.eq(#Kit.closed, closed)
Assert.len(Kit.find(list, function(w) return w.text == "check_box" end), 2)

-- 禁用项不可点。
list = List:new{ items = { { text = "a", enabled = false }, { text = "b" } } }
Assert.len(Kit.taps(list), 1)

-- 居中列表：画遮罩，面板宽 = 标准弹窗宽。
list = List:new{ items = items(3), centered = true }
Assert.is_true(list.mask)
Assert.eq(list[1]:getSize().w, 480)

-- 居中分页：末页不满也补成整页高，面板不跳；变矮（换成少项）时连底下窗口一起重画，
-- 否则网纹遮罩下露出旧面板。
list = List:new{ items = items(1), centered = true }
local per_page = list.per_page
list:setItems(items(per_page + 2))
local full_h = list[1]:getSize().h
list:goPage(2)
Assert.len(Kit.taps(list), 2)
Assert.eq(list[1]:getSize().h, full_h, "末页面板与首页同高")
Assert.eq(Kit.dirty[#Kit.dirty].widget, list)
list:setItems(items(1))
Assert.is_true(list[1]:getSize().h < full_h)
Assert.eq(Kit.dirty[#Kit.dirty].widget, "all", "面板变矮重画整屏")

-- 项自带 callback：单选代替 on_select；keep_open 的项不关窗。
local calls, on_select_n = {}, 0
list = List:new{ items = {
    { text = "a", callback = function() calls[#calls + 1] = "a" end },
    { text = "b", keep_open = true, callback = function() calls[#calls + 1] = "b" end },
}, on_select = function() on_select_n = on_select_n + 1 end }
closed = #Kit.closed
Kit.taps(list)[2]:onTapThemeArea()
Assert.eq(#Kit.closed, closed, "keep_open 不关窗")
Kit.taps(list)[1]:onTapThemeArea()
Assert.eq(Kit.closed[#Kit.closed], list)
Assert.eq(table.concat(calls, ","), "b,a")
Assert.eq(on_select_n, 0, "有 callback 不再调 on_select")

-- 多选项的 callback 拿到翻转后的状态，on_toggle 照常。
local got
multi = { { text = "a", value = "a", checked = false, callback = function(c) got = c end } }
list = List:new{ items = multi, multi = true, on_toggle = function(_, c) toggled = c end }
Kit.taps(list)[1]:onTapThemeArea()
Assert.is_true(got)
Assert.is_true(toggled)

-- current：按值选中并翻页，每项画 radio，不改调用方的 items。
local plain = items(30)
list = List:new{ items = plain, current = 20 }
Assert.eq(list.page, 2)
Assert.len(Kit.find(list, function(w) return w.text == "radio_button_checked" end), 1)
Assert.len(Kit.find(list, function(w) return w.text == "radio_button_unchecked" end), 13)
Assert.is_nil(plain[20].checked)

-- 左右滑翻页；上下滑不处理。
list = List:new{ items = items(30) }
Assert.is_true(list:onSwipeList(nil, { direction = "west" }))
Assert.eq(list.page, 2)
list:onSwipeList(nil, { direction = "east" })
Assert.eq(list.page, 1)
Assert.is_false(list:onSwipeList(nil, { direction = "north" }))

-- 分栏：底栏占位，每页少一行；切栏换成 on_tab 返回的项并翻到其 checked 项；左上按钮进标题栏。
local left_n = 0
list = List:new{
    items = items(30),
    left_icon = "sync",
    left_callback = function() left_n = left_n + 1 end,
    tabs = { tabs = { { id = "x", text = "X", icon = "home" }, { id = "y", text = "Y", icon = "home" } },
        active = "x", on_tab = function(id) return id == "y" and items(40, 35) or items(30) end },
}
Assert.eq(list.per_page, 13, "底栏 60px 挤掉一行")
Assert.eq(list[1]:getSize().h, 800, "加底栏仍铺满整屏")
local sync = Kit.find(list, function(w) return w.icon == "sync" end)
Assert.len(sync, 1)
sync[1]:onTapThemeButton()
Assert.eq(left_n, 1)
local tab_taps = Kit.taps(list)
tab_taps[#tab_taps]:onTapThemeArea()
Assert.eq(list.tabs.active, "y")
Assert.len(list.items, 40)
Assert.eq(list.page, 3, "翻到第 35 项所在页")

-- 嵌进别的窗口：按给定尺寸布局，刷新打到宿主窗口；点击范围跟着绘制位置走。
local host = {}
list = List:new{ items = items(30), width = 300, height = 400, show_parent = host }
Assert.eq(list[1]:getSize().w, 300)
Assert.eq(list[1]:getSize().h, 400)
list:goPage(2)
Assert.eq(Kit.dirty[#Kit.dirty].widget, host)
list:paintTo(Kit.canvas(), 50, 60)
Assert.eq(list.dimen.x, 50)
Assert.eq(list.dimen.y, 60)

-- 文本查看：正文区按可见行分页，翻页夹到 [1, pages]。
local viewer = TextViewer:new{ title = "日志", text = string.rep("字", 2000) }
Assert.eq(viewer.body:getAllLineCount(), 600)
Assert.eq(viewer.pages, math.ceil(600 / viewer.body:getVisLineCount()))
Assert.is_true(viewer.pages > 1)
viewer:turn(1)
Assert.eq(viewer.page, 2)
Assert.eq(viewer.body.scrolled, 1)
for _ = 1, 20 do viewer:turn(1) end
Assert.eq(viewer.page, viewer.pages)
viewer:turn(-1)
Assert.eq(viewer.page, viewer.pages - 1)
Assert.contains(Kit.texts(viewer), (viewer.pages - 1) .. " / " .. viewer.pages)
Kit.buttons(viewer)[1]:onTapThemeButton()
Assert.eq(Kit.closed[#Kit.closed], viewer, "右上角关闭")

local installed
viewer = TextViewer:new{
    title = "日志",
    text = "短",
    buttons = {
        { text = "稍后" },
        { text = "安装", callback = function() installed = true end },
    },
}
local install = Kit.find(viewer, function(w) return w.text == "安装" and w.onTapThemeButton end)[1]
install:onTapThemeButton()
Assert.is_true(installed)

return true
