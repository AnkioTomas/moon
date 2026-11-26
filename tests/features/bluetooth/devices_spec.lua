--[[--
蓝牙开关失败提示：框架仍在跑且状态没变化时，请用户以 no-framework 重启后再关。
--]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(s) return s end end

local offer = true
local restarted = false
local cb_err
local sent_on
local status = { state = "on", devices = {}, connections = {} }
package.preload["utils.mem"] = function()
    return { canOfferNoFramework = function() return offer end }
end
package.preload["utils.restart"] = function()
    return { noFramework = function() restarted = true end }
end
package.preload["features.bluetooth"] = function()
    return {
        setEnabled = function(on, cb)
            sent_on = on
            cb(false, cb_err)
        end,
        current = function() return status end,
        watch = function() return { cancel = function() end } end,
    }
end

Themed.install()
local Devices = require("features.bluetooth.devices")

local function close_off(err)
    cb_err = err
    Themed.install()
    Devices.setEnabled(false)
end

-- 关不掉，框架还在：确认框，点确定走 no-framework 重启。
close_off("蓝牙状态没有变化")
local confirm = Themed.last("confirm")
Assert.not_nil(confirm)
Assert.is_true(confirm.shown == true)
Assert.is_true(confirm.text:find("no-framework", 1, true) ~= nil)
Assert.eq(confirm.ok_text, "以 no-framework 重启")
Assert.eq(confirm.cancel_text, "取消")
Assert.is_nil(Themed.last("toast"))
confirm.ok_callback()
Assert.is_true(restarted)

-- 已经是 no-framework：只提示状态没变。
offer = false
restarted = false
close_off("蓝牙状态没有变化")
Assert.is_nil(Themed.last("confirm"))
Assert.eq(Themed.last("toast").text, "蓝牙状态没有变化")

-- 这次是要打开：不拿重启说事。
offer = true
Themed.install()
cb_err = "蓝牙状态没有变化"
Devices.setEnabled(true)
Assert.is_nil(Themed.last("confirm"))
Assert.eq(Themed.last("toast").text, "蓝牙状态没有变化")

-- 命令被系统拒绝：原样 toast。
close_off("无法控制系统蓝牙")
Assert.is_nil(Themed.last("confirm"))
Assert.eq(Themed.last("toast").text, "无法控制系统蓝牙")

-- 设备页的开关走同一条提示，目标状态是关。
offer = true
cb_err = "蓝牙状态没有变化"
status.state = "on"
Themed.install()
Devices.show()
Themed.last("list").items[1].callback()
Assert.is_false(sent_on)
Assert.not_nil(Themed.last("confirm"))
Assert.is_nil(Themed.last("toast"))
