--[[--
顶栏时钟：Resume 挂分钟心跳，Pause 拆掉，只脏时钟区域。

@module koplugin.book.ui.views.topbar.clock
--]]

local datetime = require("datetime")
local UIManager = require("ui/uimanager")
local Base = require("ui.views.topbar.base")

---@class BookTopBarClock : BookTopBarItem
local Clock = {}
Clock.__index = Clock
setmetatable(Clock, Base)
Clock.id = "clock"
Clock.align = "left"

--- 按系统的十二或二十四小时制设置格式化当前时间。
---@return string
local function clockText()
    return datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
end

--- 读取当前时间；设置隐藏或数据不可用时返回 nil。
---@return string|nil
function Clock:read()
    if not Base.visible("clock") then
        return nil
    end
    return clockText()
end

--- 构建当前时间对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Clock:createWidget()
    self.metric_widget = nil
    self.rect = nil
    self.metric_widget = Base.metric(nil, self:read())
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

--- 按下一分钟边界安排时钟刷新，仅在 Resume 阶段继续调度。
function Clock:scheduleTick()
    if not self.lifecycle:uiReady() then return end
    self:unschedule()
    self._tick = function()
        if not self.lifecycle:uiReady() then return end
        self:updateView()
        self:scheduleTick()
    end
    local delay = math.max(1, 61 - (tonumber(os.date("%S")) or 0))
    UIManager:scheduleIn(delay, self._tick)
end

--- 刷新当前时间并启动分钟对齐的定时器。
function Clock:onResume()
    self:updateView()
    self:scheduleTick()
end

--- 取消时钟定时器并清除指标及屏幕矩形引用。
function Clock:onDestroy()
    self:unschedule()
    self.metric_widget = nil
    self.rect = nil
end

return Clock
