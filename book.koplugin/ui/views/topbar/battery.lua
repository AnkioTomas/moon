--[[--
顶栏电池。充电事件立刻刷，Resume 起每 10 分钟刷一次。

@module koplugin.book.ui.views.topbar.battery
--]]

local Device = require("device")
local Base = require("ui.views.topbar.base")

---@class BookTopBarBattery : BookTopBarItem
local Battery = {}
Battery.__index = Battery
setmetatable(Battery, Base)
Battery.id = "battery"
Battery.interval = 600

--- 充电状态变化时立即更新电量文案和图标。
---@param event string|table 父组件转发的事件名称或事件对象
---@return nil
function Battery:onEvent(event)
    if event == "Charging" or event == "NotCharging" then
        self:updateView()
    end
end

--- 电池图标：非充电使用 battery_android_0..6/full，充电使用电量档位图标。
---@param pct number 阅读进度百分比，范围 0 到 100
---@param charging boolean|nil 当前是否正在充电
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

--- 读取电量百分比和充电图标；设置隐藏或数据不可用时返回 nil。
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

--- 构建电量百分比和充电图标对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Battery:createWidget()
    self.metric_widget = nil
    self.rect = nil
    local text, icon = self:read()
    self.metric_widget = Base.metric(icon or "battery_android_full", text)
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

return Battery
