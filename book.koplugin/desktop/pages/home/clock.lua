--[[--
主体：时钟。布局跟天气同构：居中大时间 + 下方两行辅文（日期 / 农历节日）。农历读 online.myrl。

@module koplugin.book.desktop.pages.home.clock
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local Myrl = require("online.myrl")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

-- 整词翻译：英文星期名拼不出「星期」+ 单字的结构。
local DOW = { "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" }

---@class BookHomeClock : BookHomeComponent
---@field time_widget table|nil
---@field detail table|nil
---@field extra table|nil
---@field _tick fun()|nil
local M = {
    id = "clock",
    label = _("时钟"),
    icon = "schedule",
}
setmetatable(M, require("desktop.pages.home.base"))
M.__index = M

--- 时间 + 两行辅文的内容高度（按主题字号实测）。
---@return number
function M.contentHeight()
    local t = Theme.current()
    return Text.line("hero", "0"):getSize().h + Text.line("caption", "0"):getSize().h * 2
        + Theme.px(t.space.xs) * 2
end

--- 返回时钟内容高度；不吃剩余空间。
---@return BookHomeHeightSpec
function M:heightRange()
    return { height = M.contentHeight() }
end

--- 组合当前日期与本地化星期文案。
---@return string
local function dateLine()
    return os.date("%Y-%m-%d") .. " " .. _(DOW[(tonumber(os.date("%w")) or 0) + 1])
end

--- 组合农历与节日名称；两项均缺失时显示占位符。
---@param data table|nil 日报数据，含 lunar / holiday 文字
---@return string
local function lunarLine(data)
    local lunar, holiday = data and data.lunar, data and data.holiday
    local parts = {}
    if type(lunar) == "string" and lunar ~= "" then
        parts[#parts + 1] = lunar
    end
    if type(holiday) == "string" and holiday ~= "" then
        parts[#parts + 1] = holiday
    end
    return #parts > 0 and table.concat(parts, " · ") or "--"
end

--- 取消本实例保存的定时回调并清除句柄。
---@param self BookHomeClock 当前视图或布局实例
local function stopTick(self)
    if self._tick then UIManager:unschedule(self._tick) end
    self._tick = nil
end

--- 居中主行 + 两行辅文的同构排版（时钟、天气共用）。
--- 两行辅文控件写回 view.detail / view.extra，供 paint 原地 setText。
---@param view BookHomeClock|BookHomeWeather 已保存 ctx / opts 的组件实例
---@param hero table 主行控件
---@param detail string 第一行辅文
---@param extra string 第二行辅文
---@param foot table|nil 辅文下方的附加行（天气预报）
---@return table
function M.stack(view, hero, detail, extra, foot)
    local t = Theme.current()
    local w, h = view.opts.width, view.opts.height
    view.detail = Text.line("caption", detail, { width = w, color = t.color.muted })
    view.extra = Text.line("caption", extra, { width = w, color = t.color.faint })
    local gap = VerticalSpan:new{ width = Theme.px(t.space.xs) }
    local col = VerticalGroup:new{ align = "center", hero, gap, view.detail, gap, view.extra }
    if foot then
        col[#col + 1] = VerticalSpan:new{ width = Theme.px(t.space.sm) }
        col[#col + 1] = foot
    end
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, col }
end

--- 按指定宽高构建时间、日期和农历节日三行内容。
---@return table
function M:createWidget()
    self.time_widget = Text.line("hero", os.date("%H:%M") --[[@as string]])
    return M.stack(self, self.time_widget, dateLine(), lunarLine(self.data))
end

--- 更新当前时间、日期及农历节日文字；文字全未变时不刷新，墨水屏每次 dirty 都是一次真实刷新。
function M:paint()
    if not self.time_widget then return end
    local time, date, lunar = os.date("%H:%M"), dateLine(), lunarLine(self.data)
    if self.time_widget.text == time and self.detail.text == date and self.extra.text == lunar then return end
    self.time_widget:setText(time)
    self.detail:setText(date)
    self.extra:setText(lunar)
    self:dirty()
end

--- 取消旧计时回调，立即绘制一次后按下一分钟边界继续调度。
function M:tick()
    if not self.time_widget then return end
    stopTick(self)
    self._tick = require("ui.guard").wrap("home clock", function()
        if not self.active then return end
        self:paint()
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), self._tick)
    end)
    self._tick()
end

--- 启动分钟计时器，先画已有日报，再订阅。
function M:onActivate()
    self.data = Myrl:current()
    self:tick()
    self._on_daily = function(data, err)
        if err or not data or data == self.data then return end
        self.data = data
        self:paint()
    end
    Myrl:watch(self._on_daily)
    Myrl:ensure()
end

--- 取消分钟计时器；不取消 online 任务。
function M:onDeactivate()
    Myrl:unwatch(self._on_daily)
    self._on_daily = nil
    stopTick(self)
end

--- 清除文字控件引用。
function M:onDestroy()
    self.time_widget = nil
    self.detail = nil
    self.extra = nil
end

return M
