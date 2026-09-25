--[[--
顶栏小组件基类：Lifecycle + 可见性 + 原地刷新。

@module koplugin.book.ui.views.topbar.base
--]]

local Blitbuffer = require("ffi/blitbuffer")
local View = require("ui.view")
local Icon = require("ui.components.icon")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local MoonSettings = require("utils.settings")
local logger = require("utils.log")

---@class BookTopBarItem : View
---@field id string 顶栏项目注册标识
---@field align string|nil "left" 进左栏，其余进右栏
---@field always boolean|nil 为真时不受 home_topbar_items 开关影响，sync 必建
---@field interval number|nil Resume 后的固定刷新间隔（秒）
---@field topbar BookTopBar 拥有本项目的顶栏实例
---@field widget table|nil View 拥有的稳定根容器
---@field metric_widget table|nil 实際图标或文字控件，与稳定根分离；nil 表示不进布局
---@field ctx BookTopBarBuildCtx|nil 当前顶栏构建尺寸
---@field rect table|nil 本项目在屏幕上的绝对刷新矩形
---@field _tick fun()|nil 当前定时刷新回调，用于取消调度
local Base = {}
Base.__index = Base
setmetatable(Base, View)
Base.ICON_SIZE = 14

--- 顶栏项目是否显示。缺失或损坏的旧配置按显示处理。
---@param id string 组件、分页或数据源的标识
---@return boolean
function Base.visible(id)
    local home = MoonSettings.get("home")
    local items = type(home.home_topbar_items) == "table" and home.home_topbar_items or {}
    return items[id] ~= false
end

--- 取得仍存活的所属桌面；顶栏或桌面已销毁时返回 nil。
---@return table|nil
function Base:desktop()
    local topbar = self.topbar
    local desktop = topbar and topbar.desktop
    if not desktop or desktop.lifecycle.state == "Destroy" or (topbar and topbar.lifecycle.state == "Destroy") then
        return nil
    end
    return desktop
end

--- 只脏自己那一块。Resume 以外不改屏。
function Base:dirty()
    if not self.lifecycle:uiReady() then return end
    local desktop = self:desktop()
    if desktop and self.rect then
        UIManager:setDirty(desktop, "ui", self.rect)
    end
end

--- 顶栏一项。有图标走图标+文案，没有就纯文字；text 空则整项省略。
---@param icon_name string|nil 图标名称；nil 时按纯文字处理
---@param text string|nil 需要展示的文字
---@param opts table|nil 布局尺寸、样式及行为选项；缺省项使用组件默认值
---@return table|nil
function Base.metric(icon_name, text, opts)
    if not text or text == "" then
        return nil
    end
    opts = opts or {}
    if not icon_name then
        return TextWidget:new{
            text = text,
            face = UI.face(opts.face or "xx_smallinfofont", opts.font_size or 12),
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end
    return Icon.label{
        name = icon_name,
        text = text,
        size = Base.ICON_SIZE,
        font_size = 12,
        gap = opts.gap or UI.sz(3),
        max_width = opts.max_width,
    }
end

--- 原地改图标/文案。显隐变化才整条重排。
---@param icon_name string|nil 图标名称；nil 时按纯文字处理
---@param text string|nil 需要展示的文字
function Base:updateMetric(icon_name, text)
    if not self.lifecycle:uiReady() then return end
    local show = text ~= nil and text ~= ""
    if show ~= (self.metric_widget ~= nil) then
        local topbar = self.topbar
        logger.dbg("topbar metric visibility change", self.id, show, self.metric_widget ~= nil)
        if topbar then topbar:updateView() end
        return
    end
    if not self.metric_widget then
        return
    end
    if icon_name then
        local icon = self.metric_widget.icon
        local tw = icon and (icon.setText and icon or icon[1])
        if tw and tw.setText then
            tw:setText(icon_name)
        end
    end
    if self.metric_widget.label then
        self.metric_widget.label:setText(text)
    elseif self.metric_widget.setText then
        self.metric_widget:setText(text)
    end
    local size = self.metric_widget.getSize and self.metric_widget:getSize()
    if size and self.rect and size.w ~= self.rect.w and self.topbar then
        self.topbar:updateView()
        return
    end
    self:dirty()
end

--- 按 read() 原地改 UI。Resume 以外不改屏。
function Base:updateView()
    local text, icon = self:read()
    self:updateMetric(icon, text)
end

--- 取消顶栏项目的定时刷新回调并清除句柄。
function Base:unschedule()
    if self._tick then
        UIManager:unschedule(self._tick)
        self._tick = nil
    end
end

--- 固定间隔刷新。Clock 的分钟对齐心跳不走这里。
---@param seconds number 刷新周期，单位秒
function Base:scheduleEvery(seconds)
    self:unschedule()
    if not self.lifecycle:uiReady() then return end
    self._tick = function()
        if not self.lifecycle:uiReady() then return end
        self:updateView()
        self:scheduleEvery(seconds)
    end
    UIManager:scheduleIn(seconds, self._tick)
end

--- 立即更新指标，并为配置了周期的项目启动定时刷新。
function Base:onResume()
    self:updateView()
    if self.interval then
        self:scheduleEvery(self.interval)
    end
end

--- 暂停顶栏项目时取消定时刷新。
function Base:onPause()
    self:unschedule()
end

--- 读当前要显示的值；子类实现。
---@return string|nil text
---@return string|nil icon
function Base:read()
    error("topbar item must implement read")
end

--- 保存构建上下文并返回 View 缓存的稳定根容器。
---@param ctx BookTopBarBuildCtx|nil 构建上下文，提供尺寸、数据源和桌面宿主
---@return table|nil
function Base:build(ctx)
    self.ctx = ctx
    return View.build(self)
end

--- 取消定时刷新并清除指标 Widget 和屏幕矩形引用。
function Base:onDestroy()
    self:unschedule()
    self.metric_widget = nil
    self.rect = nil
end

return Base
