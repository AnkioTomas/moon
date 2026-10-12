--[[--
features.passcode.pad：接真 Modal 的整屏键盘；输入上限、确定键启用条件、提交结果、解锁时吞掉返回与点空白。
@module tests.features.passcode.pad_spec
--]]

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")

local Modal = require("ui.themes.widgets.modal")
local Pad = require("features.passcode.pad")

---@param pad table
---@param key string 按钮树序：1..9、del、0、ok、取消
local function press(pad, key)
    local index = ({ del = 10, ["0"] = 11, ok = 12, cancel = 13 })[key] or tonumber(key)
    Kit.buttons(pad)[index]:onTapThemeButton()
end

local submitted = {}
local reply = "密码错误" ---@type string|true
local pad = Pad:new{
    title = "输入密码解锁",
    dismissable = false,
    on_submit = function(pin)
        submitted[#submitted + 1] = pin
        return reply
    end,
}
Assert.eq(pad.paintTo, Modal.paintTo, "不覆盖 Modal 的 guard 入口")
Assert.eq(pad.handleEvent, Modal.handleEvent)
Assert.eq(pad.panel_x, 0)
Assert.eq(pad.panel_y, 0)
Assert.len(Kit.buttons(pad), 12, "解锁时没有取消按钮")
pad:paintTo(Kit.canvas(), 0, 0)

-- 不足 4 位确定键置灰，点了不提交。
for _i, key in ipairs({ "1", "2", "3" }) do press(pad, key) end
Assert.eq(pad.pin, "123")
Assert.is_false(Kit.buttons(pad)[12].enabled)
press(pad, "ok")
Assert.len(submitted, 0)

-- 最多 6 位；删除退一位。
for _i, key in ipairs({ "4", "5", "6", "7" }) do press(pad, key) end
Assert.eq(pad.pin, "123456")
Assert.contains(Kit.texts(pad), "●●●●●●")
press(pad, "del")
press(pad, "0")
Assert.eq(pad.pin, "123450")

-- 提交被拒：清空输入、显示原因、窗口还在。
press(pad, "ok")
Assert.eq(submitted[1], "123450")
Assert.eq(pad.pin, "")
Assert.contains(Kit.texts(pad), "密码错误")
Assert.contains(Kit.texts(pad), "○○○○○○")
Assert.is_false(Kit.buttons(pad)[10].enabled, "空输入时删除键置灰")

-- 解锁窗口吞掉返回键与点按，不关窗。
local closed = #Kit.closed
Assert.is_true(pad:handleEvent({ handler = "onClose", args = {} }))
Assert.is_true(pad:handleEvent({ handler = "onTapModal", args = { nil, Kit.tap(1, 1) } }))
Assert.eq(#Kit.closed, closed)

-- 唤醒时清空没输完的位数。
press(pad, "9")
pad:clear()
Assert.eq(pad.pin, "")
Assert.contains(Kit.texts(pad), "○○○○○○")

-- 再输就清掉提示；通过后关窗。
press(pad, "1")
Assert.is_false(Kit.texts(pad)[3] == "密码错误")
reply = true
for _i, key in ipairs({ "2", "3", "4" }) do press(pad, key) end
press(pad, "ok")
Assert.eq(submitted[2], "1234")
Assert.eq(Kit.closed[#Kit.closed], pad)

-- 设置页用：可取消。
local cancel_pad = Pad:new{ title = "设置", dismissable = true, on_submit = function() return true end }
Assert.len(Kit.buttons(cancel_pad), 13)
press(cancel_pad, "cancel")
Assert.eq(Kit.closed[#Kit.closed], cancel_pad)

return true
