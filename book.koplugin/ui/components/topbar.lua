--[[--
Desktop 顶部状态条。拼装小组件，并把生命周期传下去。

布局：
  +---------------------------------------------------+
  | 12:00  [源] 源名              内存  存储  Wi‑Fi  ☀  🔋 |
  |───────────────────────────────────────────────────|
  +---------------------------------------------------+
  左：时钟、源名。右：内存、缓存、存储、Wi‑Fi、亮度、电池。

小组件跟着生命周期走：不显示的不创建；设置改了在 build 时对齐。
onStart 开工，onResume 原地刷新，onPause/onStop 停工。
本文件只排布，并在阶段变化时通知孩子。

@module koplugin.book.ui.components.topbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local UI = require("ui.components.bookui")
local Lifecycle = require("ui.lifecycle")
local logger = require("utils.log")

local Base = require("ui.components.topbar.base")
local Clock = require("ui.components.topbar.clock")
local Source = require("ui.components.topbar.source")
local Memory = require("ui.components.topbar.memory")
local Cache = require("ui.components.topbar.cache")
local Storage = require("ui.components.topbar.storage")
local Wifi = require("ui.components.topbar.wifi")
local Brightness = require("ui.components.topbar.brightness")
local Battery = require("ui.components.topbar.battery")

local SLOTS = {
    Clock, Source, Memory, Cache, Storage, Wifi, Brightness, Battery,
}

local TopBar = setmetatable({}, Lifecycle)
TopBar.__index = TopBar

---@param child table
local function retire(child)
    if child.onPause then child:onPause() end
    if child.onStop then child:onStop() end
    if child.onDestroy then child:onDestroy() end
end

function TopBar:sync()
    if self._closed then return end
    local children = {}
    for i = 1, #SLOTS do
        local class = SLOTS[i]
        local key = class.id
        local child = self[key]
        if Base.visible(key) then
            if not child then
                child = class:new(self)
                self[key] = child
                if self._created and child.onCreate then child:onCreate() end
                if self._started and child.onStart then child:onStart() end
            end
            children[#children + 1] = child
        elseif child then
            retire(child)
            self[key] = nil
        end
    end
    self._children = children
end

function TopBar.new(desktop)
    local self = setmetatable({ desktop = desktop, _children = {} }, TopBar)
    self:sync()
    return self
end

---@param self table
---@param name string
local function emit(self, name)
    for i = 1, #self._children do
        local child = self._children[i]
        local fn = child[name]
        if type(fn) == "function" then
            fn(child)
        end
    end
end

function TopBar:refresh()
    if self._closed or not self.desktop or self.desktop._closed then
        return
    end
    logger.dbg("topbar refresh", debug.traceback("", 2))
    self.desktop:refreshTopBar()
end

function TopBar:onCreate()
    self._created = true
    emit(self, "onCreate")
end

function TopBar:onStart()
    if self._closed or self._started then return end
    self._started = true
    emit(self, "onStart")
end

function TopBar:onResume()
    if self._closed then return end
    emit(self, "onResume")
end

function TopBar:onPause()
    emit(self, "onPause")
end

function TopBar:onStop()
    emit(self, "onStop")
    self._started = false
end

function TopBar:onDestroy()
    if self._closed then return end
    self._closed = true
    emit(self, "onDestroy")
end

function TopBar:sourceTapRect()
    return self.source and self.source.rect
end

function TopBar:cacheTapRect()
    return self.cache and self.cache.rect
end

--- 记录组件在顶栏上的区域，供点击和局部刷新使用。
---@param child table
---@param widget table|nil
---@param x number
---@param th number
local function place(child, widget, x, th)
    child.rect = nil
    if not widget then return end
    local size = widget.getSize and widget:getSize()
    if size then
        child.rect = Geom:new{ x = x, y = 0, w = size.w, h = th }
    end
end

--- 构建一整条顶栏 widget。
---@return table
function TopBar:build()
    local sw = Screen:getWidth()
    local th = UI.topBarH()
    local pad = UI.pagePad()
    local gap_w = UI.sz(8)
    local line_h = UI.line()
    local inner_h = th - line_h
    local inner_w = sw - pad * 2
    local ctx = { inner_w = inner_w, th = th, pad = pad }
    self:sync()

    local left = HorizontalGroup:new{ align = "center" }
    local left_w = 0
    if self.clock then
        local clock_widget = self.clock:build(ctx)
        if clock_widget then
            table.insert(left, clock_widget)
            place(self.clock, clock_widget, pad, th)
            left_w = self.clock.rect and self.clock.rect.w or 0
        end
    end
    if self.source then
        local source_widget = self.source:build(ctx)
        if source_widget then
            if #left > 0 then
                table.insert(left, HorizontalSpan:new{ width = gap_w })
                left_w = left_w + gap_w
            end
            table.insert(left, source_widget)
            place(self.source, source_widget, pad + left_w, th)
        end
    end

    local right = HorizontalGroup:new{ align = "center" }
    local metrics = {}
    local right_keys = { "memory", "cache", "storage", "wifi", "brightness", "battery" }
    for i = 1, #right_keys do
        local child = self[right_keys[i]]
        if child then
            local widget = child:build(ctx)
            if widget then
                if #metrics > 0 then
                    table.insert(right, HorizontalSpan:new{ width = gap_w })
                end
                table.insert(right, widget)
                metrics[#metrics + 1] = { child = child, widget = widget }
            end
        end
    end

    local right_w = 0
    for i, item in ipairs(metrics) do
        local size = item.widget.getSize and item.widget:getSize()
        if size then
            if i > 1 then right_w = right_w + gap_w end
            right_w = right_w + size.w
        end
    end
    local before = 0
    for i, item in ipairs(metrics) do
        place(item.child, item.widget, pad + inner_w - right_w + before, th)
        local size = item.widget.getSize and item.widget:getSize()
        if size then
            before = before + size.w + gap_w
        end
    end

    local row = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            left,
        },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            right,
        },
    }

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = th },
        VerticalGroup:new{
            align = "left",
            HorizontalGroup:new{
                HorizontalSpan:new{ width = pad },
                row,
                HorizontalSpan:new{ width = pad },
            },
            LineWidget:new{
                background = UI.rule(),
                dimen = Geom:new{ w = sw, h = line_h },
            },
        },
    }
end

return TopBar
