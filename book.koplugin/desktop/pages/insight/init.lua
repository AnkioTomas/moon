--[[--
统计页入口：经当前源读本地洞察，打开书籍详情，分发六页 UI。

不发起网络请求。读路径直查 book.catalog.readingInsightAsync（聚合本地库）；
远端写入只由源侧 syncStatsAsync 完成。计算在 book/insight_calc.lua，页面只拼装。

页面与页内卡片可在设置里开关（layout.lua 目录 + settings/insight.lua），余下的卡片自动拉伸填满。
UI 页面按需加载：
  1. insight/day.lua      - 今日（选中日）：活动环、时段、阅读段、书单
  2. insight/overview.lua - 本月：指标卡、月历、时段
  3. insight/year.lua     - 本年：月图、热力图、读完封面墙
  4. insight/ranks.lua    - 榜单：最长阅读、作者、题材
  5. insight/trends.lua   - 趋势：90 天 vs 一年、本周 vs 上周
  6. insight/goals.lua    - 进度：本月挑战、完成预测、连续记录

@module koplugin.book.desktop.pages.insight
--]]

local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookDB = require("book.books_db")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Layout = require("desktop.pages.insight.layout")
local Pager = require("ui.themes.widgets.pager")
local Input = require("ui.input")
local Text = require("ui.themes.widgets.text")
local Toast = require("ui.themes.widgets.toast")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

---@class BookInsight
---@field desktop BookDesktop
---@field state table|nil 已加载的洞察；nil 表示下次进页重读
---@field fetch_cancel table|nil 在飞读取
---@field ui_page number
---@field ui_pages number|nil 上次构建时的总页数，翻页时钳位用
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
function Insight:onEvent(event, payload)
    if event == "source_changed" then
        self:reset()
    elseif event == "stats_changed" then
        self.state = nil
    elseif event == "swipe" then
        if payload.direction == "west" then
            self:turn(1)
        elseif payload.direction == "east" then
            self:turn(-1)
        end
    end
end

--- 底部翻页条翻页（按钮、左右滑、物理翻页键共用）；到头不动不重绘。
---@param dir integer 1 下一页，-1 上一页
function Insight:turn(dir)
    local page = Input.page((self.ui_page or 1) + dir, self.ui_pages or 1)
    if page == self.ui_page then return end
    self.ui_page = page
    self.desktop:updateView()
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

--- 页面 id → 模块；锁屏统计背景按同一张表构建整页。
Insight.PAGE_MODULES = {
    day = "desktop.pages.insight.day",
    month = "desktop.pages.insight.overview",
    year = "desktop.pages.insight.year",
    ranks = "desktop.pages.insight.ranks",
    trends = "desktop.pages.insight.trends",
    goals = "desktop.pages.insight.goals",
}

--- 跳到指定页面（日历点日期回今日页）；该页被隐藏就留在原地。
---@param id string 页面 id，见 layout.lua
function Insight:switchPage(id)
    for i, page in ipairs(Layout.pages()) do
        if page.id == id then
            self.ui_page = i
            return
        end
    end
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

    local specs = Layout.pages()
    local usable = state.has_data and not state.error
    local pages = usable and #specs or 1
    local page = math.max(1, math.min(self.ui_page, pages))
    self.ui_page, self.ui_pages = page, pages
    local spec = specs[page]
    local title = spec.label
    local body
    if usable then
        if spec.id == "day" and state.selected ~= os.date("%Y-%m-%d") then title = _("当日") end
        body = require(Insight.PAGE_MODULES[spec.id]):build({
            desktop = desktop, state = state, width = content_w, height = inner_h,
            open_book = function(book) self:openBookDetail(book) end,
        })
    else
        body = Text.box("body", state.error or _("暂无阅读统计。上报后再查看。"), content_w,
            { align = "center", color = t.color.muted, transparent = true })
    end
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
                title = title,
                keys = false,
                on_page = function(target) self:turn(target - page) end,
            }),
        },
    }
end

--- 洞察原始数据 → 页面状态：默认选中今天（没有就选最近一天）。
---@param raw StatsInsight
---@return table
function Insight.stateOf(raw)
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
    return {
        has_data = raw.has_data,
        total = raw.total,
        calendar = raw.calendar,
        ym = ym,
        selected = selected,
        sessions = raw.sessions,
        finished = raw.finished,
        reading = raw.reading,
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
        finish(Insight.stateOf(res.data))
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
