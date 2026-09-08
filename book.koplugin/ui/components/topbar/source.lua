--[[--
顶栏数据源名。唤醒或换源时原地刷新。

@module koplugin.book.ui.components.topbar.source
--]]

local UI = require("ui.components.bookui")
local SourceRegistry = require("source.registry")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local Base = require("ui.components.topbar.base")

---@class BookTopBarSource : BookTopBarItem
local Source = setmetatable({}, Base)
Source.__index = Source
Source.id = "source"
Source.align = "left"

---@param event string|table
function Source:onEvent(event)
    if event == "source_changed" then
        self:refresh()
    end
end

---@return string|nil
function Source:read()
    if not Base.visible("source") then
        return nil
    end
    local id = MoonSettings.activeSourceId()
    local meta = id and SourceRegistry.meta(id)
    if meta then
        return meta.name or meta.id
    end
    return id or _("未知源")
end

---@param ctx table|nil
---@return table|nil
function Source:build(ctx)
    self.widget = nil
    self.rect = nil
    local inner_w = ctx and ctx.inner_w or 0
    self.widget = Base.metric("source", self:read(), {
        gap = UI.sz(4),
        max_width = math.floor(inner_w * 0.36),
    })
    return self.widget
end

return Source
