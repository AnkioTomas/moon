--[[--
纯按键（hasDPad）弹窗焦点导航：焦点逻辑全在 Modal 基类，各弹窗零改动。
- 绘制后按几何收集面板里的可点控件成线性链；
- 初始焦点落首项，方向键在链上走、到边夹住；
- 中心键激活焦点项，触发其回调。

触摸设备（has_dpad=false）不注册方向键、paint 不收集，弹窗退化为纯触摸，由 modal_spec / sheet_spec 覆盖。

@module tests.ui.themes.widgets.focus_nav_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
Kit.has_dpad, Kit.touch = true, false

-- 中心键 = 按下 + 松开；间隔 < HOLD_MS 为短按（激活）。
local press_key = { match = function() return true end }
local function tap(w) w:onFocusSelect(); Kit.now = 10; w:onKeyRelease(press_key); Kit.now = 0 end

-- 确认弹窗：两个按钮（取消、删除）
local Confirm = require("ui.themes.widgets.confirm")
local log = {}
local confirm = Confirm:new{
    text = "删除这本书？",
    ok_text = "删除",
    cancel_callback = function() log[#log + 1] = "cancel" end,
    ok_callback = function() log[#log + 1] = "ok" end,
}
confirm:show()
Assert.is_nil(confirm._focus_list, "绘制前没有坐标，不收集")

confirm:paintTo(Kit.canvas(), 0, 0)
Assert.not_nil(confirm._focus_list, "绘制后收集到按钮")
Assert.len(confirm._focus_list, 2)
Assert.eq(confirm._focus_idx, 1, "初始焦点落首项（取消）")

-- 按钮横排：取消在左、删除在右，用左右键走
confirm:onFocusRight()
Assert.eq(confirm._focus_idx, 2, "右键到删除")
confirm:onFocusRight()
Assert.eq(confirm._focus_idx, 2, "到右端夹住")
confirm:onFocusLeft()
Assert.eq(confirm._focus_idx, 1, "左键回取消")

-- 中心键短按激活焦点项（取消）：触发回调 + 关窗
tap(confirm)
Assert.eq(log[1], "cancel", "短按触发焦点项回调")
Assert.is_true(#Kit.closed > 0, "触发后关窗")

-- 动作菜单 Sheet：行是 Button，不经按钮行，同样被自动收集
local Sheet = require("ui.themes.widgets.sheet")
local sheet_hit = {}
local sheet = Sheet:new{ title = "操作", items = {
    { text = "第一", callback = function() sheet_hit[#sheet_hit + 1] = 1 end },
    { text = "第二", callback = function() sheet_hit[#sheet_hit + 1] = 2 end },
    { text = "禁用", enabled = false, callback = function() sheet_hit[#sheet_hit + 1] = 3 end },
} }
sheet:show()
sheet:paintTo(Kit.canvas(), 0, 0)
Assert.not_nil(sheet._focus_list, "动作菜单绘制后收集到行")
Assert.len(sheet._focus_list, 2, "禁用行不进链")
sheet:onFocusDown()
tap(sheet)
Assert.eq(sheet_hit[1], 2, "短按触发焦点行回调")

-- 列表 List：可点行被收集，中心键选中
local List = require("ui.themes.widgets.list")
local picked
local items = {}
for i = 1, 5 do items[i] = { text = "项" .. i, value = i } end
local list = List:new{ title = "选择", items = items, on_select = function(v) picked = v end }
list:show()
list:paintTo(Kit.canvas(), 0, 0)
Assert.not_nil(list._focus_list, "列表绘制后收集到行")
-- 一路下键走到末行，中心键选中它
for _step = 1, #list._focus_list do list:onFocusDown() end
tap(list)
Assert.eq(picked, 5, "短按选中末项")

-- 长按（间隔 ≥ HOLD_MS）不走短按激活：这里末项选中应被长按分流吃掉
picked = nil
list:show()
list:paintTo(Kit.canvas(), 0, 0)
list:onFocusSelect()
Kit.now = 600
list:onKeyRelease(press_key)
Kit.now = 0
Assert.is_nil(picked, "长按不触发短按激活")

return true
