--[[--
统计页入口：经当前源读本地洞察，打开书籍详情，分发三页 UI。

不发起网络请求。读路径走 SourceBase:readingInsightAsync（catalog 聚合库）；
远端写入只由源侧 syncStatsAsync 完成。

UI 页面按需加载：
  1. insight/overview.lua - 概览与日历
  2. insight/day.lua      - 当日书单
  3. insight/records.lua  - 连续记录与年度图表

@module koplugin.book.ui.desktop.insight
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local PageStrip = require("ui.components.pagestrip")
local BookDB = require("db.book")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("utils.log")
local _ = require("gettext")
local View = require("ui.view")

---@class BookInsight
---@field desktop BookDesktop
---@field state table|nil
---@field loaded boolean
---@field fetching boolean
---@field fetch_cancel table|nil
---@field ui_page number
---@field overview BookInsightOverview
---@field day BookInsightDay
---@field records BookInsightRecords
local Insight = {}
Insight.__index = Insight
setmetatable(Insight, View)

function Insight:new(opts)
    opts = opts or {}
    opts.state = opts.state
    opts.loaded = opts.loaded or false
    opts.fetching = opts.fetching or false
    opts.ui_page = opts.ui_page or 1
    opts.overview = opts.overview or require("ui.desktop.insight.overview").new()
    opts.day = opts.day or require("ui.desktop.insight.day").new()
    opts.records = opts.records or require("ui.desktop.insight.records").new()
    return View.new(self, opts)
end

---@return nil
function Insight:cancel()
    if self.fetch_cancel then
        self.fetch_cancel:cancel()
        self.fetch_cancel = nil
    end
    self.fetching = false
end

function Insight:reset()
    self:cancel()
    self.state = nil
    self.loaded = false
    self.ui_page = 1
end

function Insight:onPause()
    self:cancel()
end

function Insight:onDestroy()
    self:cancel()
end

function Insight:onCancel()
    self:cancel()
end

---@param event string
function Insight:onEvent(event)
    if event == "source_changed" then
        self:reset()
    end
end

--- 统计页点书：只认 books 表里已有的行，缺元数据就提示，不联网补全。
---@param hint table 洞察日书单条目，必须有 source_id 和 stable_id。
function Insight:openBookDetail(hint)
    local desktop = self.desktop
    if not desktop or desktop.lifecycle.state == "Destroy" then return end
    if type(hint) ~= "table" or type(hint.source_id) ~= "string"
        or type(hint.stable_id) ~= "string" then
        UIManager:show(InfoMessage:new{ text = _("没有这本书"), timeout = 2 })
        return
    end

    local book = BookDB.get(hint.source_id, hint.stable_id)
    if not book or not book.title then
        UIManager:show(InfoMessage:new{ text = _("没有这本书"), timeout = 2 })
        return
    end
    book.source_id = hint.source_id
    book.stable_id = hint.stable_id
    if hint.percent ~= nil and (not book.percent or book.percent == 0) then
        book.percent = tonumber(hint.percent) or book.percent or 0
    end
    require("ui.desktop.detail").open(desktop, "library", book)
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
        return insight.overview:build(desktop, state, width, height)
    elseif page == 2 then
        return insight.day:build(
            desktop, state, width, height,
            function(book) insight:openBookDetail(book) end
        )
    end
    return insight.records:build(state, width, height)
end

--- 构建统计 Tab 整页 UI。
---@return table
function Insight:build()
    local desktop = self.desktop
    local height = desktop:contentHeight()
    local width = desktop.dimen.w
    local page_pad = UI.pagePad()
    local content_w = math.max(UI.sz(100), width - page_pad * 2)
    local state = self.state or {}
    local body_h = math.max(1, height - PageStrip.bandH())
    local inner_h = math.max(1, body_h - page_pad * 2)

    local has_data = state.has_data and not state.error
    local pages = has_data and 3 or 1
    local page = PageStrip.clamp(self.ui_page, pages)
    self.ui_page = page
    local body = buildPage(self, page, state, content_w, inner_h)
    local filler = math.max(0, inner_h - body:getSize().h)
    local body_kids = { align = "left", body }
    if filler > 0 then table.insert(body_kids, VerticalSpan:new{ width = filler }) end

    local labels = { _("概览"), _("今日总览"), _("连续记录") }
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = height },
        VerticalGroup:new{
            align = "left",
            FrameContainer:new{
                bordersize = 0,
                padding = page_pad,
                background = Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = width, h = body_h },
                VerticalGroup:new(body_kids),
            },
            PageStrip.widget{
                width = width,
                page = page,
                pages = pages,
                center = "title",
                title = labels[page],
                on_prev = function() self.ui_page = page - 1; desktop:updateView() end,
                on_next = function() self.ui_page = page + 1; desktop:updateView() end,
            },
        },
    }
end

--- 经当前源读本地洞察（SourceBase → catalog → DB）；UI 不碰网络。
function Insight:fetch()
    if self.fetching then return end
    local desktop = self.desktop
    self:cancel()
    self.fetching = true
    local source = desktop.source
    local generation = desktop.source_generation or 0

    --- 写入统计状态并重建页面。
    ---@param state table|nil 新状态。
    local function finish(state)
        self.fetching = false
        self.fetch_cancel = nil
        self.state = state or {}
        self.loaded = true
        if desktop.lifecycle.state == "Destroy" or desktop.tab ~= "insight" then return end
        desktop:updateView()
    end

    if not source then
        finish({ has_data = false, error = _("当前数据源不可用") })
        return
    end
    local caps = source.capabilities and source:capabilities() or {}
    if caps.insight == false or type(source.readingInsightAsync) ~= "function" then
        finish({ has_data = false, error = _("当前数据源不支持统计") })
        return
    end

    self.fetch_cancel = source:readingInsightAsync(function(res, err)
        if desktop.lifecycle.state == "Destroy" or desktop.source ~= source
            or (desktop.source_generation or 0) ~= generation then
            self.fetching = false
            self.fetch_cancel = nil
            return
        end
        if not res then
            finish({ has_data = false, error = err or _("加载失败") })
            return
        end
        local applied, boom = pcall(function()
            local raw = res.data or res
            if type(raw) ~= "table" or type(raw.total) ~= "table" or type(raw.calendar) ~= "table" then
                finish({ has_data = false, error = _("统计数据无效") })
                return
            end
            local per_day = raw.calendar.days or {}
            local days = {}
            for day in pairs(per_day) do days[#days + 1] = day end
            table.sort(days)
            local today = os.date("%Y-%m-%d")
            local selected = per_day[today] and today or (days[#days] or "")
            local ym = raw.calendar.initial_ym or os.date("%Y-%m")
            local yy, mm = selected:match("^(%d%d%d%d)%-(%d%d)")
            if yy and mm then ym = yy .. "-" .. mm end
            finish({
                has_data = not not raw.has_data,
                total = raw.total,
                calendar = raw.calendar,
                ym = ym,
                selected = selected,
            })
        end)
        if not applied then
            logger.err("book insight fetch apply failed:", boom)
            finish({ has_data = false, error = tostring(boom) })
        end
    end)
end

--- 统计 widget。未加载则经源读本地洞察。
---@return table
function Insight:updateView()
    local desktop = self.desktop
    local height = desktop:contentHeight()
    local width = desktop.dimen.w
    if not self.loaded then
        UIManager:nextTick(function()
            if desktop.lifecycle.state == "Destroy" or desktop.tab ~= "insight" then return end
            self:fetch()
        end)
        self.widget = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = width, h = height },
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = height },
                TextWidget:new{
                    text = _("加载统计…"),
                    face = UI.face("cfont", 18),
                    fgcolor = UI.muted(),
                },
            },
        }
        return self.widget
    end
    self.widget = self:build()
    return self.widget
end

return Insight
