--[[--
统计页入口：经当前源读本地洞察，打开书籍详情，分发四页 UI。

不发起网络请求。读路径直查 book.catalog.readingInsightAsync（聚合本地库）；
远端写入只由源侧 syncStatsAsync 完成。

UI 页面按需加载：
  1. insight/overview.lua - 概览与日历
  2. insight/day.lua      - 当日书单
  3. insight/records.lua  - 连续记录与年度图表
  4. insight/hours.lua    - 阅读时段（仅本机记录）

@module koplugin.book.desktop.pages.insight
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookDB = require("book.books_db")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")
local Toast = require("ui.themes.widgets.toast")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

---@class BookInsight
---@field desktop BookDesktop
---@field state table|nil 已加载的洞察；nil 表示下次进页重读
---@field fetch_cancel table|nil 在飞读取
---@field ui_page number
local Insight = {}
Insight.__index = Insight

---@param opts table
---@return BookInsight
function Insight:new(opts)
    opts.ui_page = 1
    return setmetatable(opts, self)
end

function Insight:cancel()
    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end
end

function Insight:reset()
    self:cancel()
    self.state = nil
    self.ui_page = 1
end

Insight.deactivate = Insight.cancel
Insight.destroy = Insight.cancel
Insight.onCancel = Insight.cancel

---@param event string
function Insight:onEvent(event)
    if event == "source_changed" then
        self:reset()
    elseif event == "stats_changed" then
        self.state = nil
    end
end

--- 统计页点书：只认 books 表里已有的行，缺元数据就提示，不联网补全。
---@param hint table 洞察日书单条目，必须有 source_id 和 stable_id。
function Insight:openBookDetail(hint)
    local desktop = self.desktop
    if desktop.closed then return end
    local book = BookDB.get(hint.source_id, hint.stable_id)
    if not book or not book.title then
        Toast:new{ text = _("没有这本书"), timeout = 2 }:show()
        return
    end
    book.source_id = hint.source_id
    book.stable_id = hint.stable_id
    if hint.percent ~= nil and (not book.percent or book.percent == 0) then
        book.percent = hint.percent
    end
    require("desktop.detail").open(desktop, "library", book)
end

--- 构建当前页 UI；页面模块只在真正显示时加载。
---@param insight BookInsight
---@param page number 页码。
---@param state table 统计状态。
---@param width number 内容宽度。
---@param height number 内容高度。
---@return table
local function buildPage(insight, page, state, width, height)
    local desktop = insight.desktop
    if page == 1 then
        return require("desktop.pages.insight.overview"):build(desktop, state, width, height)
    elseif page == 2 then
        return require("desktop.pages.insight.day"):build(
            desktop, state, width, height,
            function(book) insight:openBookDetail(book) end
        )
    elseif page == 3 then
        return require("desktop.pages.insight.records"):build(state, width, height)
    end
    return require("desktop.pages.insight.hours"):build(state, width, height)
end

--- 构建统计 Tab 整页 UI：正文区（顶对齐）+ 以页名作标题的翻页条。
---@return table
function Insight:build()
    local desktop = self.desktop
    local t = Theme.current()
    local height = desktop:contentHeight()
    local width = desktop.dimen.w
    local pad = Theme.px(t.space.md)
    local content_w = width - pad * 2
    local state = self.state or {}
    local body_h = math.max(1, height - Theme.px(t.control.height))
    local inner_h = math.max(1, body_h - pad * 2)

    local labels = { _("概览"), _("今日总览"), _("连续记录"), _("阅读时段") }
    local pages = state.has_data and not state.error and #labels or 1
    local page = math.max(1, math.min(self.ui_page, pages))
    self.ui_page = page
    local body = buildPage(self, page, state, content_w, inner_h)
    return Box:new{
        style = { bg = t.color.page },
        width = width,
        height = height,
        VerticalGroup:new{
            align = "left",
            Box:new{
                style = {},
                width = width,
                height = body_h,
                VerticalGroup:new{
                    align = "left",
                    body,
                    VerticalSpan:new{ width = math.max(0, inner_h - body:getSize().h) },
                },
            },
            Pager.widget({
                width = width,
                page = page,
                pages = pages,
                title = labels[page],
                on_prev = function() self.ui_page = page - 1; desktop:updateView() end,
                on_next = function() self.ui_page = page + 1; desktop:updateView() end,
            }),
        },
    }
end

--- 经当前源读本地洞察（SourceBase → catalog → DB）；UI 不碰网络。
function Insight:fetch()
    if self.fetch_cancel then return end
    local desktop = self.desktop
    local source = desktop.source

    --- 写入统计状态并重建页面。
    ---@param state table 新状态。
    local function finish(state)
        self.fetch_cancel = nil
        self.state = state
        if desktop.closed or desktop.tab ~= "insight" then return end
        desktop:updateView()
    end

    if not source then
        finish({ has_data = false, error = _("当前数据源不可用") })
        return
    end

    local running = true
    local job = require("book.catalog").readingInsightAsync(source.id, function(res, err)
        running = false
        if desktop.closed or desktop.source ~= source then
            self.fetch_cancel = nil
            return
        end
        if not res then
            finish({ has_data = false, error = err or _("加载失败") })
            return
        end
        local raw = res.data
        ---@cast raw StatsInsight
        local per_day = raw.calendar.days or {}
        local days = {}
        for day in pairs(per_day) do days[#days + 1] = day end
        table.sort(days)
        local today = os.date("%Y-%m-%d")
        ---@cast today string
        local selected = per_day[today] and today or (days[#days] or "")
        local ym_now = os.date("%Y-%m")
        ---@cast ym_now string
        local ym = raw.calendar.initial_ym or ym_now
        local yy, mm = selected:match("^(%d%d%d%d)%-(%d%d)")
        if yy and mm then ym = yy .. "-" .. mm end
        finish({
            has_data = raw.has_data,
            total = raw.total,
            calendar = raw.calendar,
            ym = ym,
            selected = selected,
        })
    end)
    -- 源可能同步回调：已结束的句柄不能留下挡住下次读取。
    if running then self.fetch_cancel = job end
end

--- 统计 widget。未加载则经源读本地洞察。
---@return table
function Insight:updateView()
    local desktop = self.desktop
    if self.state then return self:build() end
    UIManager:nextTick(require("ui.guard").wrap("insight fetch", function()
        if desktop.closed or desktop.tab ~= "insight" then return end
        self:fetch()
    end))
    local t = Theme.current()
    local width, height = desktop.dimen.w, desktop:contentHeight()
    return Box:new{
        style = { bg = t.color.page },
        width = width,
        height = height,
        Text.line("body", _("加载统计…"), { color = t.color.muted }),
    }
end

return Insight
