--[[--
顶栏时钟：Resume 挂分钟心跳，Pause 拆掉，只脏时钟区域。

@module koplugin.book.ui.components.topbar.clock
--]]

local datetime = require("datetime")
local UIManager = require("ui/uimanager")
local Base = require("ui.components.topbar.base")

---@class BookTopBarClock : BookTopBarItem
local Clock = setmetatable({}, Base)
Clock.__index = Clock
Clock.id = "clock"
Clock.align = "left"

---@return string
local function clockText()
    return datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
end

---@return string|nil
function Clock:read()
    if not Base.visible("clock") then
        return nil
    end
    return clockText()
end

---@return table|nil
function Clock:build()
    self.widget = nil
    self.rect = nil
    self.widget = Base.metric(nil, self:read())
    return self.widget
end

function Clock:scheduleTick()
    if not self:uiReady() then return end
    self:unschedule()
    self._tick = function()
        if not self:uiReady() then return end
        self:updateMetric(nil, self:read())
        self:scheduleTick()
    end
    local delay = math.max(1, 61 - (tonumber(os.date("%S")) or 0))
    UIManager:scheduleIn(delay, self._tick)
end

function Clock:onResume()
    self:updateMetric(nil, self:read())
    self:scheduleTick()
end

function Clock:onDestroy()
    self:unschedule()
    self.widget = nil
    self.rect = nil
end

return Clock
