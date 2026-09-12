--[[--
顶栏数据源名。唤醒或换源时原地刷新。

@module koplugin.book.ui.views.topbar.source
--]]

local UI = require("ui.components.bookui")
local SourceRegistry = require("source.registry")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local Base = require("ui.views.topbar.base")

---@class BookTopBarSource : BookTopBarItem
local Source = {}
Source.__index = Source
setmetatable(Source, Base)
Source.id = "source"
Source.align = "left"

--- 数据源切换后刷新当前源名称。
---@param event string|table 父组件转发的事件名称或事件对象
---@return nil
function Source:onEvent(event)
    if event == "source_changed" then
        self:updateView()
    end
end

--- 读取当前数据源名称；设置隐藏或数据不可用时返回 nil。
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

--- 构建当前数据源名称对应的指标控件；隐藏时返回零尺寸占位 Widget。
---@return table|nil
function Source:createWidget()
    local ctx = self.ctx
    self.metric_widget = nil
    self.rect = nil
    local inner_w = ctx and ctx.inner_w or 0
    self.metric_widget = Base.metric("source", self:read(), {
        gap = UI.sz(4),
        max_width = math.floor(inner_w * 0.36),
    })
    return self.metric_widget or require("ui/widget/widget"):new{ dimen = require("ui/geometry"):new{ w = 0, h = 0 } }
end

return Source
