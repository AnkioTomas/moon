--[[--
顶栏小组件基类：Lifecycle + 可见性 + 原地刷新。

@module koplugin.book.ui.components.topbar.base
--]]

local Lifecycle = require("ui.lifecycle")
local Icon = require("ui.components.icon")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local MoonSettings = require("utils.settings")
local logger = require("utils.log")

local Base = setmetatable({}, Lifecycle)
Base.__index = Base
Base.ICON_SIZE = 14

function Base:new(topbar)
    return setmetatable({ topbar = topbar }, self)
end

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
    if not desktop or desktop._closed or (topbar and topbar._closed) then
        return nil
    end
    return desktop
end

--- 只脏自己那一块。
function Base:dirty()
    local desktop = self:desktop()
    if desktop and self.rect then
        UIManager:setDirty(desktop, "ui", self.rect)
    end
end

--- 通用「图标 + 文案」指标行；text 空则整项省略。
---@param icon_name string
---@param text string|nil
---@param opts table|nil
---@return table|nil
function Base.metric(icon_name, text, opts)
    if not text or text == "" then
        return nil
    end
    opts = opts or {}
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
    local show = text ~= nil and text ~= ""
    if show ~= (self.widget ~= nil) then
        local topbar = self.topbar
        logger.dbg("topbar metric visibility change", self.id, show, self.widget ~= nil)
        if topbar then topbar:refresh() end
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
    end
    local size = self.widget.getSize and self.widget:getSize()
    if size and self.rect then
        self.rect.w = size.w
    end
    self:dirty()
end

--- 读当前要显示的值；子类实现。
---@return string|nil, string|nil  text, icon
function Base:read()
end

---@param _ctx table|nil
---@return table|nil
function Base:build(_ctx)
end

return Base
