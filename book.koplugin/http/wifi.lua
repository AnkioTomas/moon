--[[--
休眠时关闭 Wi-Fi（设置 http.wifi_off_on_suspend，默认关）。

在 main.lua 的 onSuspend 末尾调用，排在后台任务暂停与 feature 钩子（如停远程服务）之后。
不传 interactive：KOReader 自己的「唤醒后恢复 Wi-Fi」偏好照常生效。

@module koplugin.book.http.wifi
--]]

local MoonSettings = require("utils.settings")

local Wifi = {}

---@return boolean
function Wifi.enabled()
    return MoonSettings.get("http").wifi_off_on_suspend == true
end

---@param on boolean
function Wifi.setEnabled(on)
    MoonSettings.get("http").wifi_off_on_suspend = on
    MoonSettings.save("http")
end

function Wifi.onSuspend()
    if not Wifi.enabled() then return end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isWifiOn() then NetworkMgr:disableWifi() end
end

return Wifi
