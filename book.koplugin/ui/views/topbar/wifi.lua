--[[--
顶栏 Wi-Fi 状态。网络事件立刻刷图标。

@module koplugin.book.ui.views.topbar.wifi
--]]

local NetworkMgr = require("ui/network/manager")
local Icon = require("ui.components.icon")
local Base = require("ui.views.topbar.base")

---@class BookTopBarWifi : BookTopBarItem
local Wifi = {}
Wifi.__index = Wifi
setmetatable(Wifi, Base)
Wifi.id = "wifi"

local NETWORK_EVENTS = {
    NetworkConnected = true,
    NetworkDisconnected = true,
    NetworkConnecting = true,
    NetworkDisconnecting = true,
}

--- 读取Wi-Fi 状态图标；设置隐藏或数据不可用时返回 nil。
---@return string|nil
function Wifi:read()
    if not Base.visible("wifi") then
        return nil
    end
    return NetworkMgr:isWifiOn() and "wifi" or "wifi_off"
end

--- 构建Wi-Fi 状态图标对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Wifi:createWidget()
    self.metric_widget = nil
    self.rect = nil
    local name = self:read()
    if not name then
        return require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
    end
    self.metric_widget = Icon.widget{ name = name, size = Base.ICON_SIZE }
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

--- 原地更新 Wi-Fi 图标；显隐状态变化时请求整条顶栏重排。
---@return nil
function Wifi:updateView()
    if not self.lifecycle:uiReady() then return end
    local name = self:read()
    if (name == nil) ~= (self.metric_widget == nil) then
        local topbar = self.topbar
        if topbar then topbar:updateView() end
        return
    end
    if not self.metric_widget then
        return
    end
    local tw = self.metric_widget.setText and self.metric_widget or self.metric_widget[1]
    if tw and tw.setText then
        tw:setText(name)
        self:dirty()
    end
end

--- 恢复显示时立即同步当前 Wi-Fi 状态。
---@return nil
function Wifi:onResume()
    self:updateView()
end

--- 接收网络连接状态事件并刷新图标。
---@param event string|table 父组件转发的事件名称或事件对象
---@return nil
function Wifi:onEvent(event)
    if NETWORK_EVENTS[event] then
        self:updateView()
    end
end

return Wifi
