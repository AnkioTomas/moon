--[[--
Desktop 顶部状态条。拼装小组件，并把生命周期传下去。

布局：
  +---------------------------------------------------+
  | 12:00  [源] 源名              内存  存储  Wi‑Fi  ☀  🔋 |
  |───────────────────────────────────────────────────|
  +---------------------------------------------------+
  左：时钟、源名。右：内存、缓存、存储、Wi‑Fi、亮度、电池。

onCreate / recreate 按设置建孩子、排 UI。关掉的走完 Pause / Stop / Destroy。
设置开关经 desktop 事件 topbar_changed 进来，不提供 refresh。

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
local UIManager = require("ui/uimanager")

local UI = require("ui.components.bookui")
local Lifecycle = require("ui.lifecycle")
local NativePanel = require("ui.panel.native")

local Base = require("ui.components.topbar.base")
local Clock = require("ui.components.topbar.clock")
local Source = require("ui.components.topbar.source")
local Memory = require("ui.components.topbar.memory")
local Cache = require("ui.components.topbar.cache")
local Storage = require("ui.components.topbar.storage")
local Wifi = require("ui.components.topbar.wifi")
local Brightness = require("ui.components.topbar.brightness")
local Battery = require("ui.components.topbar.battery")

---@type BookTopBarItem[]
local SLOTS = {
    Clock, Source, Memory, Cache, Storage, Wifi, Brightness, Battery,
}

---@class BookTopBarBuildCtx
---@field inner_w number 顶栏内容区宽度（已扣左右 padding）
---@field th number 顶栏总高度
---@field pad number 左右 padding

---@class BookTopBar : Lifecycle
---@field desktop BookDesktop|nil
---@field widget table|nil
---@field clock BookTopBarClock|nil
---@field source BookTopBarSource|nil
---@field memory BookTopBarMemory|nil
---@field cache BookTopBarCache|nil
---@field storage BookTopBarStorage|nil
---@field wifi BookTopBarWifi|nil
---@field brightness BookTopBarBrightness|nil
---@field battery BookTopBarBattery|nil
local TopBar = setmetatable({}, Lifecycle)
TopBar.__index = TopBar

--- 隐藏一项时走完暂停 / 停止 / 销毁。
---@param child BookTopBarItem
local function retire(child)
    child:onPause()
    child:onStop()
    child:onDestroy()
end

--- 按设置对齐孩子：该显示的创建，不该显示的拆掉。
function TopBar:sync()
    if self.state == "Destroy" then return end
    for i = 1, #SLOTS do
        local class = SLOTS[i]
        local key = class.id
        local child = self[key]
        if Base.visible(key) then
            if not child then
                child = class:new()
                child.topbar = self
                self[key] = child
            end
        elseif child then
            retire(child)
            self[key] = nil
        end
    end
end

---@param child BookTopBarItem|nil
---@param method string
---@param ... any
local function notify(child, method, ...)
    if child and child[method] then child[method](child, ...) end
end

---@param self BookTopBar
---@param method string
---@param ... any
local function broadcast(self, method, ...)
    for i = 1, #SLOTS do
        notify(self[SLOTS[i].id], method, ...)
    end
end

--- 点是否落在孩子记录的矩形内。
---@param rect table|nil
---@param x number
---@param y number
---@return boolean
local function hit(rect, x, y)
    return rect ~= nil
        and x >= rect.x and x < rect.x + rect.w
        and y >= rect.y and y < rect.y + rect.h
end

--- 记录组件在顶栏上的区域，供点击和局部刷新使用。
---@param child BookTopBarItem
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

--- 按当前可见孩子拼一整条顶栏。
---@return table
function TopBar:compose()
    local sw = Screen:getWidth()
    local th = UI.topBarH()
    local pad = UI.pagePad()
    local gap_w = UI.sz(8)
    local line_h = UI.line()
    local inner_h = th - line_h
    local inner_w = sw - pad * 2
    ---@type BookTopBarBuildCtx
    local ctx = { inner_w = inner_w, th = th, pad = pad }

    local left = HorizontalGroup:new{ align = "center" }
    local left_w = 0
    local right = HorizontalGroup:new{ align = "center" }
    local metrics = {}

    for i = 1, #SLOTS do
        local class = SLOTS[i]
        local child = self[class.id]
        local widget = child and child:build(ctx)
        if widget then
            if class.align == "left" then
                if #left > 0 then
                    table.insert(left, HorizontalSpan:new{ width = gap_w })
                    left_w = left_w + gap_w
                end
                table.insert(left, widget)
                place(child, widget, pad + left_w, th)
                left_w = left_w + (child.rect and child.rect.w or 0)
            else
                metrics[#metrics + 1] = { child = child, widget = widget }
            end
        end
    end

    local right_w = 0
    for i = 1, #metrics do
        local item = metrics[i]
        if i > 1 then
            table.insert(right, HorizontalSpan:new{ width = gap_w })
            right_w = right_w + gap_w
        end
        table.insert(right, item.widget)
        local size = item.widget.getSize and item.widget:getSize()
        item.w = size and size.w or 0
        right_w = right_w + item.w
    end
    local x = pad + inner_w - right_w
    for i = 1, #metrics do
        local item = metrics[i]
        place(item.child, item.widget, x, th)
        x = x + item.w + gap_w
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

--- 首帧或测试取 widget。已经 create / recreate 过就复用。
---@return table
function TopBar:build()
    if not self.widget then
        self:sync()
        self.widget = self:compose()
    end
    return self.widget
end

--- 有壳就换自己那一槽；没壳等 Desktop 首帧 rebuild。
---@param self BookTopBar
local function install(self)
    local desktop = self.desktop
    if self.state == "Destroy" or not desktop or not desktop.lifecycle
        or desktop.lifecycle.state == "Destroy" then
        return
    end
    local root = desktop[1] and desktop[1][1]
    local top = self.widget
    if not root or not top then return end
    top.overlap_offset = { 0, 0 }
    if root[2] and root[2].free then root[2]:free() end
    root[2] = top
    UIManager:setDirty(desktop, "ui", Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = UI.topBarH(),
    })
end

--- 按当前设置重建：关掉的走完关闭生命周期，新开的补到父阶段，再换 UI。
function TopBar:recreate()
    if self.state == "Destroy" then return end
    self:sync()
    local created = {}
    for i = 1, #SLOTS do
        local child = self[SLOTS[i].id]
        if child and child.state == "new" then
            created[#created + 1] = child
            child:onCreate()
        end
    end
    self.widget = self:compose()
    for i = 1, #created do
        if self.state == "Start" or self.state == "Resume" then
            created[i]:onStart()
        end
        if self.state == "Resume" then
            created[i]:onResume()
        end
    end
    install(self)
end

--- 创建：按设置建孩子并排好 UI。
function TopBar:onCreate()
    self:recreate()
end

--- 启动：通知孩子开工（时钟心跳、缓存监听）。
function TopBar:onStart()
    broadcast(self, "onStart")
end

--- 恢复：通知孩子原地刷新。
function TopBar:onResume()
    broadcast(self, "onResume")
end

--- 暂停：通知孩子停工。
function TopBar:onPause()
    broadcast(self, "onPause")
end

--- 停止：通知孩子停止运行资源。
function TopBar:onStop()
    broadcast(self, "onStop")
end

--- 销毁：通知孩子释放引用。
function TopBar:onDestroy()
    broadcast(self, "onDestroy")
    self.widget = nil
end

--- 设置改顶栏项：整条重建。其余事件原样转给孩子。
---@param event string|table
---@param payload any
function TopBar:onEvent(event, payload)
    if self.state == "Destroy" then return end
    if event == "topbar_changed" then
        self:recreate()
        return
    end
    broadcast(self, "onEvent", event, payload)
end

--- 顶栏下滑打开桌面快捷面板。
---@param _ any
---@param ges_ev table|nil
---@return boolean
function TopBar:onSwipe(_, ges_ev)
    if type(ges_ev) == "table" and ges_ev.direction == "south" then
        NativePanel.show("desktop")
    end
    return true
end

--- 顶栏点击：缓存打开任务列表，源名换源，其余打开快捷面板。
---@param _ any
---@param ges table|nil
---@return boolean
function TopBar:onTap(_, ges)
    local desktop = self.desktop
    if ges and ges.pos and desktop then
        local x, y = ges.pos.x, ges.pos.y
        if self.cache and hit(self.cache.rect, x, y) then
            self.cache:show()
            return true
        end
        if self.source and hit(self.source.rect, x, y) then
            desktop.settings.source:pickActive(desktop, desktop.plugin)
            return true
        end
    end
    NativePanel.show("desktop")
    return true
end

return TopBar
