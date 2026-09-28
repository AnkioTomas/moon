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
local marks = Kit.find(list, function(w) return w.name == "radio_button_checked" end)
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
    return type(w.name) == "string" and (w.name:match("^radio") or w.name:match("^check_box")) ~= nil
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
Assert.len(Kit.find(list, function(w) return w.name == "check_box" end), 2)

-- 禁用项不可点。
list = List:new{ items = { { text = "a", enabled = false }, { text = "b" } } }
Assert.len(Kit.taps(list), 1)

-- 居中列表：画遮罩，面板宽 = 标准弹窗宽。
list = List:new{ items = items(3), centered = true }
Assert.is_true(list.mask)
Assert.eq(list[1]:getSize().w, 480)

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

return true
