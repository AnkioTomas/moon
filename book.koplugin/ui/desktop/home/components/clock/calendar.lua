--[[--
时钟下的日历行。先画本地日期；摸鱼日报成功后再补农历/节日，只脏这一行。

@module koplugin.book.ui.desktop.home.components.clock.calendar
--]]

local Geom = require("ui/geometry")
local Myrl = require("online.myrl")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

---@class BookHomeCalendar : BookHomeComponent
---@field date_widget table|nil
---@field lunar string|nil
---@field holiday string|nil
local M = {}
setmetatable(M, require("ui.desktop.home.components.base"))
M.__index = M

local DOW = { _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六") }

---@param lunar string|nil
---@param holiday string|nil
---@return string
local function dateText(lunar, holiday)
    local text = os.date("%Y-%m-%d") .. " " .. _("星期")
        .. DOW[(tonumber(os.date("%w")) or 0) + 1]
    if type(lunar) == "string" and lunar ~= "" then
        text = text .. " · " .. lunar
    end
    if type(holiday) == "string" and holiday ~= "" then
        text = text .. " · " .. holiday
    end
    return text
end

---@param self BookHomeCalendar
---@param lunar string|nil
---@param holiday string|nil
---@param dirty boolean
local function show(self, lunar, holiday, dirty)
    if not self.date_widget then return end
    self.lunar = lunar
    self.holiday = holiday
    local text = dateText(lunar, holiday)
    if self.date_widget.text == text then return end
    self.date_widget:setText(text)
    if dirty then
        UIManager:setDirty(self.desktop, "ui", self.region)
    end
end

---@param ctx BookDesktopCtx
---@param opts BookHomeBuildOpts
---@return table
function M:build(ctx, opts)
    local w = opts.width
    local date_widget = TextWidget:new{
        text = dateText(self.lunar, self.holiday),
        face = UI.face("xx_smallinfofont", 13),
        max_width = math.max(1, w - UI.sz(20)),
        fgcolor = UI.muted(),
    }
    self.date_widget = date_widget
    self.desktop = ctx.desktop
    self.region = Geom:new{
        x = 0,
        y = opts.y or 0,
        w = w,
        h = opts.height,
    }
    if self:uiReady() then self:pull() end
    return { widget = date_widget, height = opts.height }
end

--- 拉农历/节日。失败或没有新字段就不刷，留下当前行（默认本地日期）。
function M:pull()
    if not self:uiReady() or not self.date_widget then return end
    self:addHttp(Myrl:fetch({}, function(data, err)
        if not self:uiReady() then return end
        if err then return end
        show(self, data.lunar, data.holiday, true)
    end))
end

function M:onResume()
    show(self, self.lunar, self.holiday, true)
    self:pull()
end

function M:onDestroy()
    self.date_widget = nil
    self.region = nil
    self.desktop = nil
end

return M
