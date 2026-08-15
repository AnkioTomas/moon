--[[--
统计页（桌面 Tab）：GET /index/stats/insight
  两页：① KPI + 日历  ② 当日书单（点日期自动跳转）

@module koplugin.book.ui.insight
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local BookInfo = require("ui.components.bookinfo")
local UI = require("ui.components.bookui")
local Pager = require("ui.components.pager")
local Store = require("book.store")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local InfoMessage = require("ui/widget/infomessage")
local TextWidget = require("ui/widget/textwidget")

local Insight = {}

local DOW = { _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六") }

--- 灰色弱化文案。
---@param text string
---@param width number
---@param size number|nil
---@return table
local function muted(text, width, size)
    return TextWidget:new{
        text = text,
        face = UI.face("xx_smallinfofont", size or 14),
        max_width = width,
        fgcolor = UI.muted(),
    }
end

--- 年月字符串按月偏移。
---@param ym string
---@param delta number
---@return string
local function shiftYm(ym, delta)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    y, m = tonumber(y), tonumber(m)
    if not y or not m then return ym end
    m = m + delta
    while m < 1 do m, y = m + 12, y - 1 end
    while m > 12 do m, y = m - 12, y + 1 end
    return string.format("%04d-%02d", y, m)
end

--- 年月显示文案。
---@param ym string
---@return string
local function ymLabel(ym)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    if not y then return ym end
    return T(_("%1年%2月"), y, tonumber(m))
end

--- 日期标题（可附带时长）。
---@param ymd string
---@param duration_text string|nil
---@return string
local function dayTitle(ymd, duration_text)
    local _y, m, d = ymd:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not m then return ymd end
    local date = T(_("%1月%2日"), tonumber(m), tonumber(d))
    if duration_text and duration_text ~= "" then
        return T(_("%1 · %2"), date, duration_text)
    end
    return date
end

--- 日历格对应的真实年月日；out_month=跨月灰格。
---@param y number
---@param m number
---@param day_num number
---@param days_in_month number
---@return number, number, number, boolean
local function resolveDay(y, m, day_num, days_in_month)
    if day_num >= 1 and day_num <= days_in_month then
        return y, m, day_num, false
    end
    if day_num < 1 then
        local py, pm = y, m - 1
        if pm < 1 then py, pm = y - 1, 12 end
        local pd = tonumber(os.date("%d", os.time{ year = py, month = pm + 1, day = 0 }))
        return py, pm, pd + day_num, true
    end
    local ny, nm = y, m + 1
    if nm > 12 then ny, nm = y + 1, 1 end
    return ny, nm, day_num - days_in_month, true
end

--- 清缓存并强制重新拉取统计。
---@param desktop table
local function refreshInsight(desktop)
    local source = desktop.source
    if source and source.clearCaches then
        source:clearCaches()
    end
    desktop._insight_state = nil
    desktop._insight_loaded = false
    desktop:rebuild()
end

--- 构建总时长英雄区。
---@param desktop table
---@param state table
---@param width number
---@return table
local function buildHero(desktop, state, width)
    local total_obj = state.total or {}
    local total = total_obj.total_text
    local has = state.has_data
    if state.error or not has or not total_obj.has_data or total == nil or total == "" then
        total = "—"
    end
    local hero_h = UI.sz(96)
    local tap = BookInfo.tappable(width, hero_h, function()
        refreshInsight(desktop)
    end)
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = width, h = hero_h },
        VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text = tostring(total),
                face = UI.face("cfont", 42),
                max_width = width,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = UI.sz(6) },
            muted(_("总阅读时长 · 点按刷新"), width, 13),
        },
    }
    return tap
end

--- 构建次级 KPI 三列。
---@param state table
---@param width number
---@return table
local function buildSecondary(state, width)
    local total_obj = state.total or {}
    local items = {
        { _("近7天"), total_obj.last7_text },
        { _("最长日"), total_obj.longest_day_text },
        { _("总页数"), total_obj.total_pages },
    }
    local row_h = UI.sz(48)
    local cell_w = math.floor(width / #items)
    local row = HorizontalGroup:new{ align = "center" }
    for _, item in ipairs(items) do
        local v = item[2]
        if v == nil or v == "" then v = "—" end
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = row_h },
            VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text = tostring(v),
                    face = UI.face("cfont", 15),
                    max_width = cell_w - UI.sz(4),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
                VerticalSpan:new{ width = UI.sz(4) },
                muted(item[1], cell_w - UI.sz(4), 12),
            },
        })
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = row_h },
        row,
    }
end

--- 日历单格。
---@param size number
---@param day_num number
---@param has_read boolean
---@param out_month boolean
---@param selected boolean
---@param on_tap fun()|nil
---@return table
local function calCell(size, day_num, has_read, out_month, selected, on_tap)
    local border = selected and UI.sz(2) or 0
    local kids = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = tostring(day_num),
            face = UI.face(has_read and "cfont" or "xx_smallinfofont", has_read and 13 or 12),
            fgcolor = out_month and UI.muted() or Blitbuffer.COLOR_BLACK,
        },
    }
    if has_read and not out_month then
        table.insert(kids, VerticalSpan:new{ width = UI.sz(2) })
        table.insert(kids, LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = UI.sz(4), h = UI.sz(4) },
        })
    end
    local tap = BookInfo.tappable(size, size, on_tap)
    tap[1] = FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = size, h = size },
        CenterContainer:new{
            dimen = Geom:new{ w = math.max(1, size - border * 2), h = math.max(1, size - border * 2) },
            kids,
        },
    }
    return tap
end

--- 日历月份导航按钮。
---@param label string
---@param w number
---@param h number
---@param on_tap fun()|nil
---@return table
local function navBtn(label, w, h, on_tap)
    local tap = BookInfo.tappable(w, h, on_tap)
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        TextWidget:new{
            text = label,
            face = UI.face("cfont", 22),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    return tap
end

--- 构建月历网格。
---@param desktop table
---@param state table
---@param width number
---@return table
local function buildCalendar(desktop, state, width)
    local perDay = (state.calendar and state.calendar.days) or {}
    local ym = state.ym or (state.calendar and state.calendar.initial_ym) or os.date("%Y-%m")
    local selected = state.selected or ""
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    y, m = tonumber(y), tonumber(m)
    if not y or not m then
        y, m = tonumber(os.date("%Y")), tonumber(os.date("%m"))
        ym = string.format("%04d-%02d", y, m)
    end

    local nav_h, btn_w = UI.sz(36), UI.sz(48)
    local label_w = math.max(1, width - btn_w * 2)
    local nav = HorizontalGroup:new{
        align = "center",
        navBtn("‹", btn_w, nav_h, function()
            state.ym = shiftYm(ym, -1)
            desktop:rebuild()
        end),
        CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = nav_h },
            TextWidget:new{
                text = ymLabel(ym),
                face = UI.face("cfont", 16),
                max_width = label_w,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
        navBtn("›", btn_w, nav_h, function()
            state.ym = shiftYm(ym, 1)
            desktop:rebuild()
        end),
    }

    local gap = UI.sz(2)
    local col_w = math.floor((width - gap * 6) / 7)
    local size = math.min(col_w, UI.sz(36))
    local dow_row = HorizontalGroup:new{ align = "center" }
    for i, name in ipairs(DOW) do
        if i > 1 then table.insert(dow_row, HorizontalSpan:new{ width = gap }) end
        table.insert(dow_row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = UI.sz(20) },
            muted(name, col_w, 11),
        })
    end

    local first_wday = tonumber(os.date("%w", os.time{ year = y, month = m, day = 1 })) or 0
    local dim = tonumber(os.date("%d", os.time{ year = y, month = m + 1, day = 0 })) or 30
    local total = math.ceil((first_wday + dim) / 7) * 7
    local start_day = 1 - first_wday
    local grid = VerticalGroup:new{ align = "left" }
    local row
    for i = 0, total - 1 do
        if i % 7 == 0 then
            if row then
                table.insert(grid, row)
                table.insert(grid, VerticalSpan:new{ width = gap })
            end
            row = HorizontalGroup:new{ align = "center" }
        elseif row then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        local cy, cm, cd, out = resolveDay(y, m, start_day + i, dim)
        local key = string.format("%04d-%02d-%02d", cy, cm, cd)
        local info = perDay[key]
        local secs = info and (tonumber(info.duration_seconds) or 0) or 0
        local cell = calCell(size, cd, secs > 0, out, key == selected, function()
            state.selected = key
            if out then state.ym = string.format("%04d-%02d", cy, cm) end
            desktop._insight_ui_page = 2
            desktop:rebuild()
        end)
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = size },
            cell,
        })
    end
    if row then table.insert(grid, row) end

    return VerticalGroup:new{
        align = "left",
        nav,
        VerticalSpan:new{ width = UI.sz(4) },
        dow_row,
        VerticalSpan:new{ width = UI.sz(2) },
        grid,
    }
end

--- 取路径末段文件名。
---@param path string|nil
---@return string|nil
local function basename(path)
    return (type(path) == "string" and path:match("([^/\\]+)$")) or path
end

--- 统计页点书：本地元数据优先（(source_id, stable_id) 查缓存），否则按 stable_id 搜图书馆。
---@param desktop table
---@param hint table 洞察日书单条目，必须有 ref
function Insight.openBookDetail(desktop, hint)
    if not desktop or desktop._closed or desktop._insight_opening then return end
    local ref = hint and hint.ref
    if type(ref) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("没有这本书"), timeout = 2 })
        return
    end
    local sid = ref.stable_id

    Store.findMetaAsync(ref, function(cached)
        if desktop._closed then return end
        if cached then
            -- 统计页进度比缓存新时直接改缓存副本；勿重建表（会丢 ref 等字段）
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
        if search == "" then
            search = (basename(sid) or ""):gsub("%.[^%.]+$", "")
        end
        if search == "" then
            UIManager:show(InfoMessage:new{ text = _("没有这本书"), timeout = 2 })
            return
        end

        NetworkMgr:runWhenOnline(function()
            if desktop._closed or desktop._insight_opening then return end
            desktop._insight_opening = true
            local loading = InfoMessage:new{ text = _("正在拉取书籍信息…") }
            UIManager:show(loading)
            --- 打开详情结束：关 loading 或报错。
            ---@param book table|nil
            ---@param err_text string|nil
            local function finish(book, err_text)
                desktop._insight_opening = false
                pcall(function() UIManager:close(loading) end)
                if desktop._closed then return end
                if book then
                    desktop:showDetail(book)
                else
                    UIManager:show(InfoMessage:new{ text = err_text or _("没有这本书"), timeout = 2 })
                end
            end
            local search_job
            search_job = api:listLibraryAsync({ page = 1, page_size = 50, search = search }, function(res, req_err)
                if desktop._closed then return end
                if not res then
                    finish(nil, req_err or _("拉取失败"))
                    return
                end
                local want = basename(sid)
                for _, row in ipairs(res.data or {}) do
                    if basename(BookInfo.file(row)) == want then
                        Store.remember(row)
                        finish(row)
                        return
                    end
                end
                finish(nil, _("没有这本书"))
            end)
        end)
    end)
end

--- 构建当日书单详情页。
---@param desktop table
---@param state table
---@param width number
---@param avail_h number|nil
---@return table
local function buildDayDetail(desktop, state, width, avail_h)
    local selected = state.selected or ""
    local days = (state.calendar and state.calendar.days) or {}
    local info = selected ~= "" and days[selected] or nil
    local col = VerticalGroup:new{ align = "left" }
    local used = 0
    --- 追加子控件并累计已用高度。
    ---@param w table
    ---@param wh number|nil
    local function push(w, wh)
        table.insert(col, w)
        used = used + (wh or 0)
    end

    local title = selected == "" and _("选择日期")
        or dayTitle(selected, info and info.duration_text or nil)
    local title_w = TextWidget:new{
        text = title,
        face = UI.face("cfont", 15),
        max_width = width,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    push(title_w, title_w:getSize().h)
    push(VerticalSpan:new{ width = UI.sz(10) }, UI.sz(10))

    if not info or not info.books or #info.books == 0 then
        local empty = muted(_("这一天没有阅读记录"), width)
        push(empty, empty:getSize().h)
        return col
    end

    local cw, ch, gap, row_gap = UI.sz(44), UI.sz(66), UI.sz(12), UI.sz(12)
    local more_h, shown = UI.sz(22), 0
    local plugin, api = desktop.plugin, desktop.source

    for i, book in ipairs(info.books) do
        local need = ch + (shown > 0 and row_gap or 0)
        local reserve = (i < #info.books) and (UI.sz(6) + more_h) or 0
        if avail_h and used + need + reserve > avail_h then break end
        if shown > 0 then push(VerticalSpan:new{ width = row_gap }, row_gap) end

        local sid = book.ref and book.ref.stable_id or nil
        local title_t = book.title or sid or "?"
        local author_t = (book.authors and book.authors ~= "") and book.authors or _("未知作者")
        local pct = tonumber(book.percent) or 0
        if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end

        local cover = select(1, BookInfo.cover(plugin, api, book, cw, ch, {
            badge = false,
            show_parent = desktop,
        }))

        local meta_w = math.max(1, width - cw - gap)
        local meta = VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = title_t,
                face = UI.face("cfont", 14),
                max_width = meta_w,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = UI.sz(4) },
            muted(author_t, meta_w, 12),
            VerticalSpan:new{ width = UI.sz(8) },
            UI.progressBar(meta_w, UI.sz(6), pct),
        }
        local tap = BookInfo.tappable(width, ch, function()
            Insight.openBookDetail(desktop, book)
        end)
        tap[1] = HorizontalGroup:new{
            align = "center",
            cover,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{ dimen = Geom:new{ w = meta_w, h = ch }, meta },
        }
        push(tap, ch)
        shown = shown + 1
    end

    local rest = #info.books - shown
    if rest > 0 then
        push(VerticalSpan:new{ width = UI.sz(6) }, UI.sz(6))
        local more = muted(T(_("另有 %1 本未显示"), rest), width)
        push(more, more:getSize().h)
    end
    return col
end

--- 构建概览页（KPI + 日历）。
---@param desktop table
---@param state table
---@param content_w number
---@return table
local function buildOverview(desktop, state, content_w)
    local col = VerticalGroup:new{ align = "left", buildHero(desktop, state, content_w) }
    if state.error then
        table.insert(col, VerticalSpan:new{ width = UI.sz(12) })
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = UI.sz(24) },
            muted(state.error, content_w),
        })
    elseif not state.has_data then
        table.insert(col, VerticalSpan:new{ width = UI.sz(12) })
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = UI.sz(40) },
            muted(_("暂无阅读统计。上报后再查看。"), content_w),
        })
    else
        table.insert(col, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(col, buildSecondary(state, content_w))
        table.insert(col, VerticalSpan:new{ width = UI.sz(16) })
        table.insert(col, buildCalendar(desktop, state, content_w))
        table.insert(col, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(col, muted(_("点选日期查看当日书单"), content_w))
    end
    return col
end

--- 构建统计 Tab 整页 UI。
---@param desktop table
---@return table
function Insight.build(desktop)
    local h = desktop:contentHeight()
    local w = desktop.dimen.w
    local page_pad = UI.sz(10)
    local content_w = math.max(UI.sz(100), w - page_pad * 2)
    local state = desktop._insight_state or {}
    local body_h = math.max(1, h - Pager.bandH())
    local inner_h = math.max(1, body_h - page_pad * 2)

    local has_day = state.has_data and not state.error
    local pages = has_day and 2 or 1
    local page = Pager.clamp(desktop._insight_ui_page, pages)
    desktop._insight_ui_page = page

    local body = (page == 1 or not has_day)
        and buildOverview(desktop, state, content_w)
        or buildDayDetail(desktop, state, content_w, inner_h)
    local filler = math.max(0, inner_h - body:getSize().h)
    local body_kids = { align = "left", body }
    if filler > 0 then
        table.insert(body_kids, VerticalSpan:new{ width = filler })
    end

    local handlers = {
        info_text = pages > 1 and (page == 1 and _("概览") or _("当日")) or nil,
        on_prev = function() desktop._insight_ui_page = page - 1 desktop:rebuild() end,
        on_next = function() desktop._insight_ui_page = page + 1 desktop:rebuild() end,
        on_first = function() desktop._insight_ui_page = 1 desktop:rebuild() end,
        on_last = function() desktop._insight_ui_page = pages desktop:rebuild() end,
    }

    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        VerticalGroup:new{
            align = "left",
            FrameContainer:new{
                bordersize = 0,
                padding = page_pad,
                background = Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = w, h = body_h },
                VerticalGroup:new(body_kids),
            },
            Pager.band(w, page, pages, handlers),
        },
    }
end

--- 异步拉取阅读统计 insight。
---@param desktop table
function Insight.fetch(desktop)
    if desktop._insight_fetching then return end
    desktop._insight_fetching = true
    if desktop._insight_fetch_cancel then
        desktop._insight_fetch_cancel:cancel()
        desktop._insight_fetch_cancel = nil
    end
    local source = desktop.source
    local generation = desktop.source_generation or 0

    --- 写入统计状态并重建。
    ---@param state table|nil
    local function finish(state)
        desktop._insight_fetching = false
        desktop._insight_fetch_cancel = nil
        desktop._insight_state = state or {}
        desktop._insight_loaded = true
        if desktop._closed or desktop.tab ~= "stats" then return end
        desktop:rebuild()
    end

    if not source or not source.configured or not source:configured() then
        finish({ has_data = false, error = _("请先配置数据源") })
        return
    end
    local caps = source.capabilities and source:capabilities() or {}
    if caps.insight == false then
        finish({ has_data = false, error = _("当前数据源不支持统计") })
        return
    end

    if not source.readingInsightAsync then
        finish({ has_data = false, error = _("当前数据源不支持统计") })
        return
    end
    desktop._insight_fetch_cancel = source:readingInsightAsync(function(res, err)
        if desktop._closed or desktop.source ~= source
            or (desktop.source_generation or 0) ~= generation then
            return
        end
        if not res then
            finish({ has_data = false, error = err or _("加载失败") })
            return
        end
        local applied, boom = pcall(function()
            local raw = res.data or res
            if type(raw) ~= "table" then
                finish({ has_data = false, error = _("响应数据无效") })
                return
            end
            local data = raw
            if type(raw.total) ~= "table" or type(raw.calendar) ~= "table" then
                finish({ has_data = false, error = _("响应数据无效") })
                return
            end
            local perDay = (data.calendar and data.calendar.days) or {}
            local days = {}
            for day in pairs(perDay) do table.insert(days, day) end
            table.sort(days)
            local selected = days[#days] or ""
            local ym = (data.calendar and data.calendar.initial_ym) or os.date("%Y-%m")
            local yy, mm = selected:match("^(%d%d%d%d)%-(%d%d)")
            if yy and mm then ym = yy .. "-" .. mm end
            finish({
                has_data = not not data.has_data,
                total = data.total,
                calendar = data.calendar,
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

--- Desktop rebuild 入口：未加载则触发 fetch。
---@param desktop table
---@return table
function Insight.page(desktop)
    local h = desktop:contentHeight()
    local w = desktop.dimen.w
    if not desktop._insight_loaded then
        UIManager:nextTick(function()
            if desktop._closed or desktop.tab ~= "stats" then return end
            Insight.fetch(desktop)
        end)
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            background = Blitbuffer.COLOR_WHITE,
            dimen = Geom:new{ w = w, h = h },
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
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
