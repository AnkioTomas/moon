--[[--
顶栏 Wi-Fi 状态。唤醒时原地刷新图标。

@module koplugin.book.ui.components.topbar.wifi
--]]

local NetworkMgr = require("ui/network/manager")
local Icon = require("ui.components.icon")
local Base = require("ui.components.topbar.base")

local Wifi = setmetatable({}, Base)
Wifi.__index = Wifi
Wifi.id = "wifi"

---@return string|nil
function Wifi:read()
    if not Base.visible("wifi") then
        return nil
    end
    return NetworkMgr:isWifiOn() and "wifi" or "wifi_off"
end

---@return table|nil
function Wifi:build()
    self.widget = nil
    self.rect = nil
    local name = self:read()
    if not name then
        return nil
    end
    self.widget = Icon.widget{ name = name, size = Base.ICON_SIZE }
    return self.widget
end

function Wifi:onResume()
    local name = self:read()
    if (name == nil) ~= (self.widget == nil) then
        local topbar = self.topbar
        if topbar then topbar:refresh() end
        return
    end
    if not self.widget then
        return
    end
    local tw = self.widget.setText and self.widget or self.widget[1]
    if tw and tw.setText then
        tw:setText(name)
        self:dirty()
    end
end

return Wifi
