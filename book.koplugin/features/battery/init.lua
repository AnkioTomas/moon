--[[--
电池用法统计生命周期：休眠 / 唤醒 / 充放电切换时累计百分比变化。
无 UI；设置页读 `features.battery.stats`。

@module koplugin.book.features.battery
--]]

local Stats = require("features.battery.stats")

local Battery = {}

local started = false

--- FM / Reader 各调一次 onCreate，只装载一次落盘数据。
function Battery.onCreate()
    if started then return end
    started = true
    Stats.ensure()
end

function Battery.onSuspend()
    Stats.onSuspend()
end

function Battery.onResume()
    Stats.onResume()
end

function Battery.onExit()
    Stats.save()
end

Battery.events = {
    Charging = function() Stats.onCharging() end,
    NotCharging = function() Stats.onNotCharging() end,
}

return Battery
