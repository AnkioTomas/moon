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

-- 年月日时分五列：整行不超出弹窗内宽，每列仍容得下自己的数字。
local Theme = require("ui.themes")
spin = Spin:new{ fields = {
    { value = 2026, min = 1970, max = 2099 },
    { value = 10, min = 1, max = 12, format = fmt2 },
    { value = 14, min = 1, max = 31, format = fmt2 },
    { value = 1, min = 0, max = 23, format = fmt2 },
    { value = 11, min = 0, max = 59, format = fmt2 },
} }
local total = Theme.px(spin.theme.space.lg) * 4
for _idx, button in ipairs(Kit.buttons(spin)) do
    if button.icon == "add" then total = total + button.width end
end
Assert.is_true(total <= spin:innerWidth(), "五列整行不溢出")

-- 四列三位数字在 hero 下放不下：降到仍放得下「120」的最大字号，列宽不把数字截成省略号。
local TextWidget = require("ui/widget/textwidget")
TextWidget.getSize = function(self)
    local size = self.face and self.face.size or 40
    local w = #self.text * size
    if self.max_width and w > self.max_width then w = self.max_width end
    return { w = w, h = size }
end
local theme = Theme.current()
spin = Spin:new{ fields = {
    { value = 0, min = 0, max = 120, step = 5, label = "上" },
    { value = 0, min = 0, max = 120, step = 5, label = "右" },
    { value = 0, min = 0, max = 120, step = 5, label = "下" },
    { value = 0, min = 0, max = 120, step = 5, label = "左" },
} }
local size = spin.labels[1].face.size
local gap = Theme.px(theme.space.lg)
local function rowAt(sz) return 3 * sz * 4 + gap * 3 end
Assert.is_true(size < theme.font.hero, "hero 放不下就降字号")
Assert.is_true(size >= theme.font.caption)
Assert.is_true(rowAt(size) <= spin:innerWidth(), "降到的字号放得下四列 120")
Assert.is_true(rowAt(size + 1) > spin:innerWidth(), "取的是放得下的最大字号")
Assert.is_true(spin.labels[1].max_width >= 3 * size, "列宽够画 120，不截成省略号")
buttons = Kit.buttons(spin)
buttons[1]:onTapThemeButton()
buttons[1]:onTapThemeButton()
Assert.eq(spin.labels[1].text, "10")
Assert.is_true(spin.labels[1].max_width >= 2 * size, "两位数仍在列宽里")

-- 降到说明文字仍放不下：停在 caption，整行不溢出。
TextWidget.getSize = function(self)
    local size = self.face and self.face.size or 40
    local w = #self.text * size * 100
    if self.max_width and w > self.max_width then w = self.max_width end
    return { w = w, h = size }
end
spin = Spin:new{ fields = {
    { value = 0, min = 0, max = 120 },
    { value = 0, min = 0, max = 120 },
    { value = 0, min = 0, max = 120 },
    { value = 0, min = 0, max = 120 },
} }
Assert.eq(spin.labels[1].face.size, theme.font.caption, "字号不再小于说明文字")
total = Theme.px(theme.space.lg) * 3
for _idx, button in ipairs(Kit.buttons(spin)) do
    if button.icon == "add" then total = total + button.width end
end
Assert.is_true(total <= spin:innerWidth(), "降无可降时整行仍不溢出")

return true
