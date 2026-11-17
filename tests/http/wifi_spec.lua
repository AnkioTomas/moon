local Assert = require("support.assert")
local cfg = { http = {} }
package.preload["utils.settings"] = function()
    return { get = function(name) return cfg[name] end, save = function() end }
end

local calls = 0
local wifi_on = true
package.loaded["ui/network/manager"] = {
    isWifiOn = function() return wifi_on end,
    disableWifi = function() calls = calls + 1 end,
}
package.loaded["http.wifi"] = nil
local Wifi = require("http.wifi")

Assert.is_true(not Wifi.enabled(), "默认关")
Wifi.onSuspend()
Assert.eq(calls, 0, "关着开关不碰 Wi-Fi")

Wifi.setEnabled(true)
Assert.is_true(Wifi.enabled())
Wifi.onSuspend()
Assert.eq(calls, 1, "休眠时关 Wi-Fi")

wifi_on = false
Wifi.onSuspend()
Assert.eq(calls, 1, "已经关了不重复关")

Wifi.setEnabled(false)
Assert.is_true(not cfg.http.wifi_off_on_suspend)
