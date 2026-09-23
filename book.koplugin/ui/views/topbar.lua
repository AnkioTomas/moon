--[[--
Desktop 顶部状态条。拼装小组件，并把生命周期传下去。

布局：
  +---------------------------------------------------+
  | 12:00  [源] 源名              内存  存储  Wi‑Fi  ☀  🔋 |
  +---------------------------------------------------+
左：时钟、源名。右：内存、缓存、存储、Wi‑Fi、亮度、电池。

onCreate / build 建孩子排 UI。关掉的走完 Pause / Stop / Destroy。
设置开关经 desktop 事件 topbar_changed → updateView。

@module koplugin.book.ui.views.topbar
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Screen = Device.screen

local UI = require("ui.components.bookui")
local View = require("ui.view")
local NativePanel = require("ui.panel.native")

local Base = require("ui.views.topbar.base")
local Clock = require("ui.views.topbar.clock")
local Source = require("ui.views.topbar.source")
local Memory = require("ui.views.topbar.memory")
local Cache = require("ui.views.topbar.cache")
local Storage = require("ui.views.topbar.storage")
local Wifi = require("ui.views.topbar.wifi")
local Brightness = require("ui.views.topbar.brightness")
local Battery = require("ui.views.topbar.battery")

---@type BookTopBarItem[]
local SLOTS = {
    Clock, Source, Memory, Cache, Storage, Wifi, Brightness, Battery,
}

---@class BookTopBarBuildCtx
---@field inner_w number 顶栏内容区宽度（已扣左右 padding）
---@field th number 顶栏总高度
---@field pad number 左右 padding

---@class BookTopBar : View
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
local TopBar = {}
TopBar.__index = TopBar
setmetatable(TopBar, View)


--- 按设置对齐孩子：该显示的创建，不该显示的拆掉。always 槽位必建。
---@return nil
function TopBar:sync()
    if self.lifecycle.state == "Destroy" then return end
    for i = 1, #SLOTS do
        local class = SLOTS[i]
        local key = class.id
        local child = self[key]
        local want = class.always or Base.visible(key)
        if want then
            if not child then
                child = class:new()
                child.topbar = self
                child.name = "topbar." .. key
                self[key] = child
                self.children[key] = child
            end
        elseif child then
            child:onDestroy()
            self[key] = nil
            self.children[key] = nil
        end
    end
end

--- 调用指定子视图的事件或生命周期方法；不存在的接收者直接跳过。
---@param child BookTopBarItem|nil 要包装或接收事件的子控件
---@param method string 子组件上的方法名
---@param ... any 原样传给目标方法的参数
---@return nil
local function notify(child, method, ...)
    if child and child[method] then child[method](child, ...) end
end

--- 按组件注册顺序把同一事件和参数分发给子视图。
---@param self BookTopBar 当前视图或布局实例
---@param method string 子组件上的方法名
---@param ... any 原样传给目标方法的参数
---@return nil
local function broadcast(self, method, ...)
    for i = 1, #SLOTS do
        notify(self[SLOTS[i].id], method, ...)
    end
end

--- 点是否落在孩子记录的矩形内。
---@param rect table|nil 屏幕绝对矩形，或返回该矩形的函数
---@param x number 目标区域左上角横坐标，单位像素
---@param y number 目标区域左上角纵坐标，单位像素
---@return boolean
local function hit(rect, x, y)
    return rect ~= nil
        and x >= rect.x and x < rect.x + rect.w
        and y >= rect.y and y < rect.y + rect.h
end

--- 记录组件在顶栏上的区域，供点击和局部刷新使用。
---@param child BookTopBarItem 要包装或接收事件的子控件
---@param widget table|nil 参与布局或绘制的 Widget
---@param x number 目标区域左上角横坐标，单位像素
---@param th number 顶栏总高度，单位像素
---@return nil
local function place(child, widget, x, th)
    child.rect = nil
    if not widget then return end
    local size = widget.getSize and widget:getSize()
    if size then
        child.rect = Geom:new{ x = x, y = 0, w = size.w, h = th }
    end
end

--- 按当前可见孩子拼一整条顶栏。
---@param self BookTopBar 当前视图或布局实例
---@return table
local function assemble(self)
    local sw = self.width or Screen:getWidth()
    local th = self.height or UI.topBarH()
    local pad = UI.pagePad()
    local gap_w = UI.sz(8)
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
        local widget
        if child then
            child.ctx = ctx
            widget = child.widget and child:rebuild() or child:build(ctx)
        end
        if widget and child.metric_widget then
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
        dimen = Geom:new{ w = inner_w, h = th },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = th },
            left,
        },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = th },
            right,
        },
    }

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = sw, h = th },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = pad },
            row,
            HorizontalSpan:new{ width = pad },
        },
    }
end

--- 有壳就换自己那一槽；没壳等 Desktop:build。
---@param self BookTopBar 当前视图或布局实例
---@return nil
local function install(self)
    local desktop = self.desktop
    if self.lifecycle.state == "Destroy" or not desktop or not desktop.lifecycle
        or desktop.lifecycle.state == "Destroy" then
        return
    end
    local root = desktop[1] and desktop[1][1]
    local top = self.widget
    if not root or not top then return end
    top.overlap_offset = { 0, 0 }
    desktop.view:replaceRegion("topbar", top)
end

--- 同步顶栏项目并补发创建阶段，按当前屏幕宽度组装左右分区。
---@return table widget 顶栏内容树
function TopBar:createWidget()
    self:sync()
    for i = 1, #SLOTS do
        local child = self[SLOTS[i].id]
        if child and child.lifecycle.state == "new" then child:onCreate() end
    end
    return assemble(self)
end

--- 重排顶栏内容并恢复新增项目，将稳定根节点安装回桌面。
---@return table
function TopBar:updateView()
    if self.lifecycle.state == "Destroy" then return self.widget end
    self:rebuild()
    for i = 1, #SLOTS do
        local child = self[SLOTS[i].id]
        if child and child.lifecycle.state == "Create" and self.lifecycle.state == "Resume" then
            child:onResume()
        end
    end
    install(self)
    return self.widget
end

--- 创建：按设置建孩子并排好 UI。
---@return nil
function TopBar:onCreate()
    self.host = not self.offscreen and self.desktop or nil
    self:build()
end

--- 恢复：通知孩子原地刷新（updateView）。
---@return nil
function TopBar:onResume()
    broadcast(self, "onResume")
end

--- 暂停：只停正在 Resume 的孩子。
---@return nil
function TopBar:onPause()
    for i = 1, #SLOTS do
        local child = self[SLOTS[i].id]
        if child and child.lifecycle.state == "Resume" then
            child:onPause()
        end
    end
end

--- 销毁：通知孩子释放引用。
---@return nil
function TopBar:onDestroy()
    broadcast(self, "onDestroy")
    self.widget = nil
end

--- 设置改顶栏项 / 换源：updateView（源名文案随活跃源变）。
---@param event string|table 父组件转发的事件名称或事件对象
---@param payload any 与事件一起传入的数据
---@return nil
function TopBar:onEvent(event, payload)
    if self.lifecycle.state == "Destroy" then return end
    if event == "topbar_changed" or event == "source_changed" then
        self:updateView()
        return
    end
    broadcast(self, "onEvent", event, payload)
end

--- 顶栏下滑打开桌面快捷面板。
---@param _ any 事件框架传入但本实现不使用的参数
---@param ges_ev table|nil KOReader 手势数据，含方向和位置
---@return boolean
function TopBar:onSwipe(_, ges_ev)
    if type(ges_ev) == "table" and ges_ev.direction == "south" then
        NativePanel.show("desktop")
    end
    return true
end

--- 顶栏点击：缓存打开任务列表，源名换源，其余打开快捷面板。
---@param _ any 事件框架传入但本实现不使用的参数
---@param ges table|nil KOReader 手势数据，含方向和位置
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
