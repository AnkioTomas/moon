--[[--
ui.themes.widgets.spin：多列步进、回绕 / 停边界、按列顺序回传、不改调用方 fields。

@module tests.ui.themes.widgets.spin_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("soft")

local Spin = require("ui.themes.widgets.spin")

local fmt2 = function(v) return string.format("%02d", v) end
local fields = {
    { value = 23, min = 0, max = 23, wrap = true, label = "时", format = fmt2 },
    { value = 5, min = 0, max = 55, step = 5, label = "分", format = fmt2 },
}
local got
local spin = Spin:new{ title = "提醒", fields = fields, callback = function(...) got = { ... } end }
Assert.eq(spin.labels[1].text, "23")
Assert.eq(spin.labels[2].text, "05")
-- 每列：+ / - 两个按钮，最后是取消 / 确定。
local buttons = Kit.buttons(spin)
Assert.len(buttons, 6)
Assert.eq(buttons[1].icon, "add")
Assert.eq(buttons[2].icon, "remove")

-- 回绕列：23 + 1 → 0；停边界列：5 - 5 → 0，再减仍是 0。
buttons[1]:onTapThemeButton()
Assert.eq(spin.values[1], 0)
Assert.eq(spin.labels[1].text, "00")
buttons[4]:onTapThemeButton()
buttons[4]:onTapThemeButton()
Assert.eq(spin.values[2], 0)
buttons[3]:onTapThemeButton()
Assert.eq(spin.values[2], 5)
Assert.eq(fields[1].value, 23, "不改调用方 fields")
Assert.eq(Kit.dirty[#Kit.dirty].mode(), "fast")

-- 确定：先关窗，按列顺序传值。
buttons[6]:onTapThemeButton()
Assert.eq(Kit.closed[#Kit.closed], spin)
Assert.eq(got[1], 0)
Assert.eq(got[2], 5)

-- 单列就是一个参数；取消走 cancel_callback 不回调 callback。
local single, cancelled
spin = Spin:new{
    fields = { { value = 3, min = 1, max = 3 } },
    callback = function(v) single = v end,
    cancel_callback = function() cancelled = true end,
}
buttons = Kit.buttons(spin)
buttons[1]:onTapThemeButton()
Assert.eq(spin.values[1], 3, "不回绕时停在上界")
Assert.eq(spin.labels[1].text, "3")
buttons[3]:onTapThemeButton()
Assert.is_true(cancelled)
Assert.is_nil(single)
buttons[4]:onTapThemeButton()
Assert.eq(single, 3)

return true
