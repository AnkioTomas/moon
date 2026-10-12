--[[--
ui.themes.widgets.input：贴顶面板、焦点切换换键盘改描边、点外面先收键盘、按字段顺序回传文本。

@module tests.ui.themes.widgets.input_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("soft")

local Input = require("ui.themes.widgets.input")

local got, cancelled
local dialog = Input:new{
    title = "登录",
    fields = {
        { label = "账号", text = "ankio" },
        { label = "密码", text_type = "password", height = 60 },
    },
    callback = function(...) got = { ... } end,
    cancel_callback = function() cancelled = true end,
}
local a, b = dialog.inputs[1], dialog.inputs[2]
-- 键盘窗口在栈顶时，按钮 / 字段 / 面板外的点按要靠这个标记才转到弹窗。
Assert.is_true(dialog.is_always_active)
Assert.is_true(a.focused)
Assert.is_false(b.focused)
Assert.eq(b.text_type, "password")
Assert.eq(b.height, 60)
Assert.is_true(b.scroll)
Assert.eq(a.parent, dialog)
-- 有方向键的设备（含模拟器）点字段后 InputText 会调 parent:getFocusableWidgetXY，缺了即抛错。
Assert.is_nil(dialog:getFocusableWidgetXY(a))
-- soft 控件无边，输入框仍至少描 1px、底色用页面色（InputText 文本区是白底）。
Assert.eq(dialog.frames[1].style.border, 1)
Assert.eq(dialog.frames[1].style.bg, 0xFF)
Assert.eq(dialog.frames[1].style.border_color, 0x00)
Assert.eq(dialog.frames[2].style.border_color, 0x99)

-- 贴顶给键盘让位。
dialog:paintTo(Kit.canvas(), 0, 0)
Assert.eq(dialog.panel_y, 16)

-- 上屏弹第一个字段的键盘。
dialog:onShow()
Assert.is_true(a.kb)

-- 点第二个字段：旧字段失焦收键盘，新字段聚焦弹键盘，描边跟着换。
dialog:onSwitchFocus(b)
Assert.is_false(a.focused)
Assert.is_false(a.kb)
Assert.is_true(b.focused)
Assert.is_true(b.kb)
Assert.eq(dialog.focus_idx, 2)
Assert.eq(dialog.frames[1].style.border_color, 0x99)
Assert.eq(dialog.frames[2].style.border_color, 0x00)
-- 再点已聚焦字段：只把键盘弹回来。
b.kb = false
dialog:onSwitchFocus(b)
Assert.is_true(b.kb)
Assert.eq(dialog.focus_idx, 2)

-- 点面板外：键盘开着先收键盘不关窗；再点才等同取消。
local closed = #Kit.closed
Assert.is_true(dialog:onTapModal(nil, Kit.tap(1, 790)))
Assert.is_false(b.kb)
Assert.eq(#Kit.closed, closed)
Assert.is_nil(cancelled)
dialog:onTapModal(nil, Kit.tap(1, 790))
Assert.is_true(cancelled)
Assert.eq(Kit.closed[#Kit.closed], dialog)

-- 确定：按字段顺序回传当前文本；关窗收起全部键盘。
dialog = Input:new{ fields = { { text = "x" }, { text = "y" } }, callback = function(...) got = { ... } end }
dialog.inputs[1].text = "改过"
dialog:onShow()
Kit.buttons(dialog)[2]:onTapThemeButton()
Assert.eq(got[1], "改过")
Assert.eq(got[2], "y")
Assert.is_false(dialog.inputs[1].kb)

-- actions：插在取消与确定之间，收当前文本，不关窗。
local probed
dialog = Input:new{
    fields = { { text = "Shanghai" } },
    actions = { { text = "测试", callback = function(city) probed = city end } },
    callback = function() end,
}
closed = #Kit.closed
local row = Kit.buttons(dialog)
Assert.len(row, 3)
dialog.inputs[1].text = "Tokyo"
row[2]:onTapThemeButton()
Assert.eq(probed, "Tokyo")
Assert.eq(#Kit.closed, closed, "action 不关窗")

return true
