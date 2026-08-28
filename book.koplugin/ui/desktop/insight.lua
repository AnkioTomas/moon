--[[--
统计页入口：负责拉取状态、打开书籍详情和三页 UI 分发。

UI 页面按需加载：
  1. insight/overview.lua - 概览与日历
  2. insight/day.lua      - 当日书单
  3. insight/records.lua  - 连续记录与年度图表

@module koplugin.book.ui.desktop.insight
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("ui.components.bookinfo")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Pager = require("ui.components.pager")
local Store = require("book.store")
local BookDB = require("utils.db.book")
local UI = require("ui.components.bookui")
local UIManager = require("ui/uimanager")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local META_TTL = 7 * 24 * 60 * 60

local Insight = {}

--- 取路径末段文件名。
---@param path string|nil 文件路径。
---@return string|nil
local function basename(path)
    return (type(path) == "string" and path:match("([^/\\]+)$")) or path
end

--- 统计页点书：优先使用本地缓存，缓存过期后按文件名从书库查询。
---@param desktop table 桌面实例。
---@param hint table 洞察日书单条目，必须有 source_id 和 stable_id。
function Insight.openBookDetail(desktop, hint)
    if not desktop or desktop._closed or desktop._insight_opening then return end
    if type(hint) ~= "table" or type(hint.source_id) ~= "string"
        or type(hint.stable_id) ~= "string" then
        UIManager:show(InfoMessage:new{ text = _("没有这本书"), timeout = 2 })
        return
    end

    local stable_id = hint.stable_id
    local cached = BookDB.get(hint.source_id, stable_id)
    local fetched_at = cached and tonumber(cached.fetched_at) or 0
    if cached and cached.title and fetched_at > 0 and os.time() - fetched_at < META_TTL then
        cached.source_id = hint.source_id
        cached.stable_id = stable_id
        if hint.percent ~= nil and (not cached.percent or cached.percent == 0) then
            cached.percent = tonumber(hint.percent) or cached.percent or 0
        end
        desktop:showDetail(cached)
        return
    end

    local api = desktop.source
    if not api or not api.configured or not api:configured() then
        UIManager:show(InfoMessage:new{ text = _("请先配置数据源"), timeout = 2 })
        return
    end
    local search = hint.title or ""
    if search == "" then search = (basename(stable_id) or ""):gsub("%.[^%.]+$", "") end
    if search == "" then
        UIManager:show(InfoMessage:new{ text = _("没有这本书"), timeout = 2 })
        return
    end

    NetworkMgr:runWhenOnline(function()
        if desktop._closed or desktop._insight_opening then return end
        desktop._insight_opening = true
        local loading = InfoMessage:new{ text = _("正在拉取书籍信息…") }
        UIManager:show(loading)
        --- 结束书籍详情查询并关闭加载提示。
        ---@param book table|nil 查询到的书籍。
        ---@param err_text string|nil 错误文案。
        local function finish(book, err_text)
            desktop._insight_opening = false
            UIManager:close(loading)
            if desktop._closed then return end
            if book then
                desktop:showDetail(book)
            else
                UIManager:show(InfoMessage:new{ text = err_text or _("没有这本书"), timeout = 2 })
            end
        end
        api:listLibraryAsync({ page = 1, page_size = 50, search = search }, function(res, req_err)
            if desktop._closed then return end
            if not res then
                finish(nil, req_err or _("拉取失败"))
                return
            end
            local wanted = basename(stable_id)
            for _, row in ipairs(res.data or {}) do
                if basename(BookInfo.file(row)) == wanted then
                    Store.rememberMany({ row })
                    finish(row)
                    return
                end
            end
            finish(nil, _("没有这本书"))
        end)
    end)
end

--- 构建当前页 UI；页面模块只在真正显示时加载。
---@param desktop table 桌面实例。
---@param page number 页码。
---@param state table 统计状态。
---@param width number 内容宽度。
---@param height number 内容高度。
---@return table
local function buildPage(desktop, page, state, width, height)
    if page == 1 then
        return require("ui.desktop.insight.overview").build(desktop, state, width, height)
    elseif page == 2 then
        return require("ui.desktop.insight.day").build(
            desktop, state, width, height,
            function(book) Insight.openBookDetail(desktop, book) end
        )
    end
    return require("ui.desktop.insight.records").build(state, width, height)
end

--- 构建统计 Tab 整页 UI。
---@param desktop table 桌面实例。
---@return table
function Insight.build(desktop)
    local height = desktop:contentHeight()
    local width = desktop.dimen.w
    local page_pad = UI.sz(10)
    local content_w = math.max(UI.sz(100), width - page_pad * 2)
    local state = desktop._insight_state or {}
    local body_h = math.max(1, height - Pager.bandH())
    local inner_h = math.max(1, body_h - page_pad * 2)

    local has_data = state.has_data and not state.error
    local pages = has_data and 3 or 1
    local page = Pager.clamp(desktop._insight_ui_page, pages)
    desktop._insight_ui_page = page
    local body = buildPage(desktop, page, state, content_w, inner_h)
    local filler = math.max(0, inner_h - body:getSize().h)
    local body_kids = { align = "left", body }
    if filler > 0 then table.insert(body_kids, VerticalSpan:new{ width = filler }) end

    local labels = { _("概览"), _("今日总览"), _("连续记录") }
    local handlers = {
        info_text = pages > 1 and labels[page] or nil,
        on_prev = function() desktop._insight_ui_page = page - 1 desktop:rebuild() end,
        on_next = function() desktop._insight_ui_page = page + 1 desktop:rebuild() end,
        on_first = function() desktop._insight_ui_page = 1 desktop:rebuild() end,
        on_last = function() desktop._insight_ui_page = pages desktop:rebuild() end,
    }

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
            Pager.band(width, page, pages, handlers),
        },
    }
end

--- 异步拉取阅读统计 insight。
---@param desktop table 桌面实例。
function Insight.fetch(desktop)
    if desktop._insight_fetching then return end
    desktop._insight_fetching = true
    if desktop._insight_fetch_cancel then
        desktop._insight_fetch_cancel:cancel()
        desktop._insight_fetch_cancel = nil
    end
    local source = desktop.source
    local generation = desktop.source_generation or 0

    --- 写入统计状态并重建页面。
    ---@param state table|nil 新状态。
    local function finish(state)
        desktop._insight_fetching = false
        desktop._insight_fetch_cancel = nil
        desktop._insight_state = state or {}
        desktop._insight_loaded = true
        if desktop._closed or desktop.tab ~= "stats" then return end
        desktop:rebuild()
    end

    if not source then finish({ has_data = false, error = _("当前数据源不可用") }); return end
    local caps = source.capabilities and source:capabilities() or {}
    if caps.insight == false or not source.readingInsightAsync then
        finish({ has_data = false, error = _("当前数据源不支持统计") })
        return
    end

    --- 向当前源拉统计并归一化成插件内部状态；期间换源或关桌面则丢弃结果。
    --- 解析用 pcall 包住：源返回的结构不受本地控制，脏数据只该退化成一条错误提示。
    local function loadInsight()
        desktop._insight_fetch_cancel = source:readingInsightAsync(function(res, err)
            if desktop._closed or desktop.source ~= source
                or (desktop.source_generation or 0) ~= generation then return end
            if not res then
                finish({ has_data = false, error = err or _("加载失败") })
                return
            end
            local applied, boom = pcall(function()
                local raw = res.data or res
                if type(raw) ~= "table" or type(raw.total) ~= "table" or type(raw.calendar) ~= "table" then
                    finish({ has_data = false, error = _("响应数据无效") })
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

    local SourceCapabilities = require("types.book_source").SourceCapabilities
    local summary = require("utils.db.stats").summaryBySource(source.id)
    if SourceCapabilities.supportsStatsPull(source)
        and (tonumber(summary.total_seconds) or 0) <= 0 then
        require("book.stats").pullInBackground(source, {
            force = true,
            on_done = function()
                if desktop._closed or desktop.source ~= source
                    or (desktop.source_generation or 0) ~= generation then return end
                loadInsight()
            end,
        })
        return
    end

    loadInsight()
end

--- Desktop rebuild 入口：未加载则触发 fetch。
---@param desktop table 桌面实例。
---@return table
function Insight.page(desktop)
    local height = desktop:contentHeight()
    local width = desktop.dimen.w
    if not desktop._insight_loaded then
        UIManager:nextTick(function()
            if desktop._closed or desktop.tab ~= "stats" then return end
            Insight.fetch(desktop)
        end)
        return FrameContainer:new{
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
    end
    return Insight.build(desktop)
end

return Insight
