--[[--
顶栏电池。充电事件立刻刷，Resume 起每 10 分钟刷一次。

@module koplugin.book.ui.components.topbar.battery
--]]

local Device = require("device")
local Base = require("ui.components.topbar.base")

---@class BookTopBarBattery : BookTopBarItem
local Battery = setmetatable({}, Base)
Battery.__index = Battery
Battery.id = "battery"
Battery.interval = 600

---@param event string|table
function Battery:onEvent(event)
    if event == "Charging" or event == "NotCharging" then
        self:refresh()
    end
end

--- 电池图标：非充电使用 battery_android_0..6/full，充电使用电量档位图标。
---@param pct number
---@param charging boolean|nil
---@return string
local function batteryIconName(pct, charging)
    if charging then
        if pct <= 20 then return "battery_charging_20_2" end
        if pct <= 30 then return "battery_charging_30_2" end
        if pct <= 50 then return "battery_charging_50_2" end
        if pct <= 60 then return "battery_charging_60_2" end
        if pct <= 80 then return "battery_charging_80_2" end
        return "battery_android_bolt"
    end
    if pct >= 100 then
        return "battery_android_full"
    end
    return "battery_android_" .. tostring(math.min(6, math.floor(pct * 7 / 100)))
end

---@return string|nil, string|nil
function Battery:read()
    if not Base.visible("battery") then
        return nil
    end
    if not (Device:hasBattery() and Device.powerd) then
        return nil
    end
    local pct = Device.powerd:getCapacity()
    if type(pct) ~= "number" then
        return nil
    end
    pct = math.max(0, math.min(100, tonumber(pct) or 0))
    return string.format("%d%%", math.floor(pct + 0.5)),
        batteryIconName(pct, Device.powerd:isCharging())
end

---@return table|nil
function Battery:build()
    self.widget = nil
    self.rect = nil
    local text, icon = self:read()
    self.widget = Base.metric(icon or "battery_android_full", text)
    return self.widget
end

return Battery
