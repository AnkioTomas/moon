--[[--
顶栏小组件基类：Lifecycle + 可见性 + 原地刷新。

@module koplugin.book.ui.components.topbar.base
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Lifecycle = require("ui.lifecycle")
local Icon = require("ui.components.icon")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local MoonSettings = require("utils.settings")
local logger = require("utils.log")

---@class BookTopBarItem : Lifecycle
---@field id string
---@field interval number|nil Resume 后的固定刷新间隔（秒）
---@field topbar BookTopBar
---@field widget table|nil
---@field rect table|nil
---@field _tick fun()|nil
local Base = setmetatable({}, Lifecycle)
Base.__index = Base
Base.ICON_SIZE = 14

--- 顶栏项目是否显示。缺失或损坏的旧配置按显示处理。
---@param id string
---@return boolean
function Base.visible(id)
    local home = MoonSettings.get("home")
    local items = type(home.home_topbar_items) == "table" and home.home_topbar_items or {}
    return items[id] ~= false
end

---@return table|nil
function Base:desktop()
    local topbar = self.topbar
    local desktop = topbar and topbar.desktop
    if not desktop or desktop.lifecycle.state == "Destroy" or (topbar and topbar.state == "Destroy") then
        return nil
    end
    return desktop
end

--- 只脏自己那一块。Resume 以外不改屏。
function Base:dirty()
    if not self:uiReady() then return end
    local desktop = self:desktop()
    if desktop and self.rect then
        UIManager:setDirty(desktop, "ui", self.rect)
    end
end

--- 顶栏一项。有图标走图标+文案，没有就纯文字；text 空则整项省略。
---@param icon_name string|nil
---@param text string|nil
---@param opts table|nil
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
---@param icon_name string|nil
---@param text string|nil
function Base:updateMetric(icon_name, text)
    if not self:uiReady() then return end
    local show = text ~= nil and text ~= ""
    if show ~= (self.widget ~= nil) then
        local topbar = self.topbar
        logger.dbg("topbar metric visibility change", self.id, show, self.widget ~= nil)
        if topbar then topbar:recreate() end
        return
    end
    if not self.widget then
        return
    end
    if icon_name then
        local icon = self.widget.icon
        local tw = icon and (icon.setText and icon or icon[1])
        if tw and tw.setText then
            tw:setText(icon_name)
        end
    end
    if self.widget.label then
        self.widget.label:setText(text)
    elseif self.widget.setText then
        self.widget:setText(text)
    end
    local size = self.widget.getSize and self.widget:getSize()
    if size and self.rect then
        self.rect.w = size.w
    end
    self:dirty()
end

--- 按 read() 原地刷新。Resume 以外不改屏。
function Base:refresh()
    local text, icon = self:read()
    self:updateMetric(icon, text)
end

function Base:unschedule()
    if self._tick then
        UIManager:unschedule(self._tick)
        self._tick = nil
    end
end

--- 固定间隔刷新。Clock 的分钟对齐心跳不走这里。
---@param seconds number
function Base:scheduleEvery(seconds)
    self:unschedule()
    if not self:uiReady() then return end
    self._tick = function()
        if not self:uiReady() then return end
        self:refresh()
        self:scheduleEvery(seconds)
    end
    UIManager:scheduleIn(seconds, self._tick)
end

function Base:onResume()
    self:refresh()
    if self.interval then
        self:scheduleEvery(self.interval)
    end
end

function Base:onPause()
    self:unschedule()
end

function Base:onStop()
    self:unschedule()
end

function Base:onDestroy()
    self:unschedule()
end

--- 读当前要显示的值；子类实现。
---@return string|nil, string|nil  text, icon
function Base:read()
end

---@param _ctx BookTopBarBuildCtx|nil
---@return table|nil
function Base:build(_ctx)
end

return Base
