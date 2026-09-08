--[[--
顶栏时钟：自己管分钟心跳，只脏时钟区域。

@module koplugin.book.ui.components.topbar.clock
--]]

local Blitbuffer = require("ffi/blitbuffer")
local TextWidget = require("ui/widget/textwidget")
local datetime = require("datetime")
local UIManager = require("ui/uimanager")
local UI = require("ui.components.bookui")
local Base = require("ui.components.topbar.base")

local Clock = setmetatable({}, Base)
Clock.__index = Clock
Clock.id = "clock"

---@return string
local function clockText()
    return datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
end

---@return table|nil
function Clock:build()
    self.widget = nil
    self.rect = nil
    if not Base.visible("clock") then
        return nil
    end
    self.widget = TextWidget:new{
        text = clockText(),
        face = UI.face("xx_smallinfofont", 12),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    return self.widget
end

function Clock:refreshClock()
    local desktop = self:desktop()
    if not desktop then return end
    if self.widget then
        self.widget:setText(clockText())
        local size = self.widget.getSize and self.widget:getSize()
        if size and self.rect then
            self.rect.w = size.w
        end
        self:dirty()
    end
    desktop:refreshHomeClock()
end

function Clock:scheduleTick()
    if self._tick then
        UIManager:unschedule(self._tick)
    end
    self._tick = function()
        if not self:desktop() then return end
        self:refreshClock()
        self:scheduleTick()
    end
    local delay = math.max(1, 61 - (tonumber(os.date("%S")) or 0))
    UIManager:scheduleIn(delay, self._tick)
end

function Clock:onStart()
    if self._started then return end
    self._started = true
    self:scheduleTick()
end

function Clock:onResume()
    self:refreshClock()
    self:scheduleTick()
end

function Clock:onPause()
    if self._tick then
        UIManager:unschedule(self._tick)
        self._tick = nil
    end
end

function Clock:onStop()
    self:onPause()
    self._started = false
end

function Clock:onDestroy()
    self:onPause()
    self._started = false
end


return Clock
