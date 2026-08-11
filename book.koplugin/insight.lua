--[[--
统计页（桌面 Tab）：从服务端 GET /index/stats/insight 拉多维统计
  大数字 hero · 精简次级指标 · 日历 · 当日封面书单

@module koplugin.book.insight
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Cover = require("cover")
local UI = require("bookui")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ScrollableContainer
do
    local ok, mod = pcall(require, "ui/widget/container/scrollablecontainer")
    if ok then ScrollableContainer = mod end
end

local Insight = {}

local DOW = {
    _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六"),
}

local function tappable(w, h, on_tap)
    local tap = InputContainer:new{
        dimen = Geom:new{ w = w, h = h },
    }
    tap.ges_events = {
        TapInsight = {
            GestureRange:new{
                ges = "tap",
                range = function() return tap.dimen end,
            },
        },
    }
    tap.onTapInsight = function()
        if on_tap then on_tap() end
        return true
    end
    return tap
end

local function mutedLine(text, width)
    return TextWidget:new{
        text = text,
        face = UI.face("xx_smallinfofont", 14),
        max_width = width,
        fgcolor = UI.muted(),
    }
end

local function pad2(n)
    return string.format("%02d", n)
end

local function shiftYm(ym, delta)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    y, m = tonumber(y), tonumber(m)
    if not y or not m then
        return ym
    end
    m = m + delta
    while m < 1 do
        m = m + 12
        y = y - 1
    end
    while m > 12 do
        m = m - 12
        y = y + 1
    end
    return string.format("%04d-%02d", y, m)
end

local function ymLabel(ym)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    if not y then return ym end
    return T(_("%1年%2月"), y, tonumber(m))
end

local function dayTitle(ymd, duration_text)
    local _y, m, d = ymd:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not m then
        return ymd
    end
    local date = T(_("%1月%2日"), tonumber(m), tonumber(d))
    if duration_text and duration_text ~= "" then
        return T(_("%1 · %2"), date, duration_text)
    end
    return date
end

local function refreshInsight(desktop)
    local Api = require("api")
    Api.clearInsightCache()
    desktop._insight_state = nil
    desktop._insight_loaded = false
    desktop:rebuild()
end

local function prefetchCover(api, plugin, filename)
    if not filename then return end
    Cover.ensureAsync(api, plugin, filename, nil)
end

--- 大数字 hero：总时长；整块点按刷新
local function buildHero(desktop, state, width)
    local activity = state.readingActivity or {}
    local kpi = activity.kpi or {}
    local total = kpi.totalReadingTime
    if state.error or not state.hasData or not activity.hasData or total == nil or total == "" then
        total = "—"
    end

    local hero_h = UI.sz(108)
    local tap = tappable(width, hero_h, function()
        refreshInsight(desktop)
    end)
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = width, h = hero_h },
        VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text = tostring(total),
                face = UI.face("cfont", 48),
                max_width = width,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = UI.sz(6) },
            TextWidget:new{
                text = _("总阅读时长 · 点按刷新"),
                face = UI.face("xx_smallinfofont", 13),
                max_width = width,
                fgcolor = UI.muted(),
            },
        },
    }
    return tap
end

--- 一行四列次级指标（无边框）
local function buildSecondary(state, width)
    local activity = state.readingActivity or {}
    local kpi = activity.kpi or {}
    local items = {
        { _("近7天"), kpi.last7DaysReadTime },
        { _("最长"), kpi.longestDay },
        { _("页数"), kpi.totalPagesRead },
        { _("单日页"), kpi.mostPagesInADay },
    }
    local row_h = UI.sz(52)
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
                TextWidget:new{
                    text = item[1],
                    face = UI.face("xx_smallinfofont", 12),
                    max_width = cell_w - UI.sz(4),
                    fgcolor = UI.muted(),
                },
            },
        })
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = width, h = row_h },
        row,
    }
end

--- 日历格：白底；有记录用字重 + 小点；选中加粗边框
local function calCell(size, day_num, has_read, out_month, selected, on_tap)
    local border = selected and UI.sz(2) or 0
    local fg = out_month and UI.muted() or Blitbuffer.COLOR_BLACK
    local face_size = has_read and 13 or 12
    local face_name = has_read and "cfont" or "xx_smallinfofont"
    local inner_w = math.max(1, size - border * 2)
    local inner_h = math.max(1, size - border * 2)

    local kids = VerticalGroup:new{
        align = "center",
        TextWidget:new{
            text = tostring(day_num),
            face = UI.face(face_name, face_size),
            fgcolor = fg,
        },
    }
    if has_read and not out_month then
        table.insert(kids, VerticalSpan:new{ width = UI.sz(2) })
        table.insert(kids, LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = UI.sz(4), h = UI.sz(4) },
        })
    end

    local body = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = inner_h },
        kids,
    }

    local tap = tappable(size, size, on_tap)
    tap[1] = FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = size, h = size },
        body,
    }
    return tap
end

local function buildCalendar(desktop, state, width)
    local perDay = state.perDay or {}
    local ym = state.ym or state.initialYm or os.date("%Y-%m")
    local selected = state.selected or ""
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    y, m = tonumber(y), tonumber(m)
    if not y or not m then
        y, m = tonumber(os.date("%Y")), tonumber(os.date("%m"))
        ym = string.format("%04d-%02d", y, m)
    end

    local nav_h = UI.sz(36)
    local btn_w = UI.sz(48)
    local label_w = math.max(1, width - btn_w * 2)
    local prev = tappable(btn_w, nav_h, function()
        state.ym = shiftYm(ym, -1)
        desktop:rebuild()
    end)
    prev[1] = CenterContainer:new{
        dimen = Geom:new{ w = btn_w, h = nav_h },
        TextWidget:new{
            text = "‹",
            face = UI.face("cfont", 22),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    local next = tappable(btn_w, nav_h, function()
        state.ym = shiftYm(ym, 1)
        desktop:rebuild()
    end)
    next[1] = CenterContainer:new{
        dimen = Geom:new{ w = btn_w, h = nav_h },
        TextWidget:new{
            text = "›",
            face = UI.face("cfont", 22),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    local nav = HorizontalGroup:new{
        align = "center",
        prev,
        CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = nav_h },
            TextWidget:new{
                text = ymLabel(ym),
                face = UI.face("cfont", 16),
                max_width = label_w,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
        next,
    }

    local gap = UI.sz(2)
    local col_w = math.floor((width - gap * 6) / 7)
    local size = math.min(col_w, UI.sz(36))

    local dow_row = HorizontalGroup:new{ align = "center" }
    for i, name in ipairs(DOW) do
        if i > 1 then
            table.insert(dow_row, HorizontalSpan:new{ width = gap })
        end
        table.insert(dow_row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = UI.sz(20) },
            TextWidget:new{
                text = name,
                face = UI.face("xx_smallinfofont", 11),
                fgcolor = UI.muted(),
            },
        })
    end

    local first_wday = tonumber(os.date("%w", os.time{ year = y, month = m, day = 1 })) or 0
    local days_in_month = tonumber(os.date("%d", os.time{ year = y, month = m + 1, day = 0 })) or 30
    local total = math.ceil((first_wday + days_in_month) / 7) * 7
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
        local day_num = start_day + i
        local cell_y, cell_m, cell_d = y, m, day_num
        local out = false
        if day_num < 1 then
            out = true
            cell_m = m - 1
            if cell_m < 1 then
                cell_m = 12
                cell_y = y - 1
            end
            cell_d = tonumber(os.date("%d", os.time{ year = cell_y, month = cell_m + 1, day = 0 })) + day_num
        elseif day_num > days_in_month then
            out = true
            cell_m = m + 1
            if cell_m > 12 then
                cell_m = 1
                cell_y = y + 1
            end
            cell_d = day_num - days_in_month
        end
        local key = string.format("%04d-%02d-%s", cell_y, cell_m, pad2(cell_d))
        local info = perDay[key]
        local has_read = info and (info.duration or 0) > 0
        local cell = calCell(size, cell_d, has_read, out, key == selected, function()
            state.selected = key
            if out then
                state.ym = string.format("%04d-%02d", cell_y, cell_m)
            end
            desktop:rebuild()
        end)
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = size },
            cell,
        })
    end
    if row then
        table.insert(grid, row)
    end

    return VerticalGroup:new{
        align = "left",
        nav,
        VerticalSpan:new{ width = UI.sz(4) },
        dow_row,
        VerticalSpan:new{ width = UI.sz(2) },
        grid,
    }
end

--- 当日书单：小封面 + 书名/作者 + 时长 + 细进度条
local function buildDayDetail(desktop, state, width)
    local selected = state.selected or ""
    local perDay = state.perDay or {}
    local info = selected ~= "" and perDay[selected] or nil

    local col = VerticalGroup:new{ align = "left" }
    local title
    if selected == "" then
        title = _("选择日期")
    elseif info then
        title = dayTitle(selected, info.durationText)
    else
        title = dayTitle(selected, nil)
    end
    table.insert(col, TextWidget:new{
        text = title,
        face = UI.face("cfont", 15),
        max_width = width,
        fgcolor = Blitbuffer.COLOR_BLACK,
    })
    table.insert(col, VerticalSpan:new{ width = UI.sz(10) })

    if not info or not info.books or #info.books == 0 then
        table.insert(col, mutedLine(_("这一天没有阅读记录"), width))
        return col
    end

    local cw = UI.sz(40)
    local ch = UI.sz(60)
    local gap = UI.sz(12)
    local plugin = desktop.plugin
    local api = desktop.api

    for i, book in ipairs(info.books) do
        if i > 1 then
            table.insert(col, VerticalSpan:new{ width = UI.sz(10) })
        end
        local filename = book.filename
        local title_t = book.title or filename or "?"
        local author_t = (book.authors and book.authors ~= "") and book.authors or _("未知作者")
        local pct = tonumber(book.progress) or 0
        if pct < 0 then pct = 0 end
        if pct > 100 then pct = 100 end
        local dur = tostring(book.durationText or "")

        local path = Cover.cachedPath(plugin, filename)
        local cover_w = Cover.widget(path, cw, ch, title_t)
        if not path and filename then
            prefetchCover(api, plugin, filename)
        end

        local meta_w = math.max(1, width - cw - gap)
        local bar_w = math.max(1, meta_w - UI.sz(64))
        local meta = VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = title_t,
                face = UI.face("cfont", 14),
                max_width = meta_w,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
            VerticalSpan:new{ width = UI.sz(4) },
            TextWidget:new{
                text = author_t,
                face = UI.face("xx_smallinfofont", 12),
                max_width = meta_w,
                fgcolor = UI.muted(),
            },
            VerticalSpan:new{ width = UI.sz(8) },
            HorizontalGroup:new{
                align = "center",
                CenterContainer:new{
                    dimen = Geom:new{ w = bar_w, h = UI.sz(10) },
                    UI.progressBar(bar_w, UI.sz(6), pct),
                },
                HorizontalSpan:new{ width = UI.sz(8) },
                TextWidget:new{
                    text = dur,
                    face = UI.face("xx_smallinfofont", 12),
                    max_width = UI.sz(56),
                    fgcolor = UI.muted(),
                },
            },
        }

        local row = HorizontalGroup:new{
            align = "center",
            cover_w,
            HorizontalSpan:new{ width = gap },
            LeftContainer:new{
                dimen = Geom:new{ w = meta_w, h = ch },
                meta,
            },
        }

        local tap = tappable(width, ch, function()
            if filename and desktop.showDetail then
                desktop:showDetail({
                    filename = filename,
                    bookName = book.title,
                    title = book.title,
                    author = book.authors,
                    progressPercent = pct,
                })
            end
        end)
        tap[1] = row
        table.insert(col, tap)
    end
    return col
end

function Insight.build(desktop)
    local h = desktop:contentHeight()
    local w = desktop.dimen.w
    local page_pad = UI.sz(16)
    local avail_w = math.max(UI.sz(120), w - page_pad * 2)
    local sb_gutter = 0
    if ScrollableContainer then
        if ScrollableContainer.getScrollbarWidth then
            sb_gutter = ScrollableContainer:getScrollbarWidth()
        else
            local Device = require("device")
            sb_gutter = 3 * Device.screen:scaleBySize(6)
        end
    end
    local content_w = math.max(UI.sz(100), avail_w - sb_gutter)
    local section_gap = UI.sz(20)
    local state = desktop._insight_state or {}

    local col = VerticalGroup:new{ align = "left" }
    table.insert(col, buildHero(desktop, state, content_w))

    if state.error then
        table.insert(col, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = UI.sz(24) },
            mutedLine(state.error, content_w),
        })
    elseif not state.hasData then
        table.insert(col, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = UI.sz(40) },
            mutedLine(_("暂无阅读统计。上报后再查看。"), content_w),
        })
    else
        table.insert(col, VerticalSpan:new{ width = UI.sz(4) })
        table.insert(col, buildSecondary(state, content_w))
        table.insert(col, VerticalSpan:new{ width = section_gap })
        table.insert(col, buildCalendar(desktop, state, content_w))
        table.insert(col, VerticalSpan:new{ width = section_gap })
        table.insert(col, buildDayDetail(desktop, state, content_w))
    end

    table.insert(col, VerticalSpan:new{ width = UI.sz(28) })

    local col_widget = VerticalGroup:new(col)
    local body_h = col_widget:getSize().h
    local body = LeftContainer:new{
        dimen = Geom:new{ w = content_w, h = body_h },
        col_widget,
    }
    local scroll_h = h - page_pad * 2
    local content
    if ScrollableContainer and body_h > scroll_h then
        content = ScrollableContainer:new{
            dimen = Geom:new{ w = avail_w, h = scroll_h },
            show_parent = desktop,
            body,
        }
        desktop.cropping_widget = content
    else
        desktop.cropping_widget = nil
        content = body
    end

    return FrameContainer:new{
        bordersize = 0,
        padding = page_pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        dimen = Geom:new{ w = w, h = h },
        LeftContainer:new{
            dimen = Geom:new{ w = avail_w, h = math.min(body_h, scroll_h) },
            content,
        },
    }
end

function Insight.fetch(desktop)
    if desktop._insight_fetching then return end
    desktop._insight_fetching = true
    local api = desktop.api

    local function finish(state)
        desktop._insight_fetching = false
        desktop._insight_state = state or {}
        desktop._insight_loaded = true
        if desktop._closed or desktop.tab ~= "stats" then return end
        desktop:rebuild()
    end

    local function run()
        if not api or not api:configured() then
            finish({
                hasData = false,
                error = _("请先配置服务器"),
            })
            return
        end

        local ok, res_or_err, err = pcall(function()
            return api:readingInsight()
        end)
        local res = ok and res_or_err or nil
        if not res then
            local msg = (not ok and tostring(res_or_err)) or err or _("加载失败")
            logger.warn("book insight failed:", msg)
            finish({
                hasData = false,
                error = msg,
            })
            return
        end

        local data = res.data or res
        if type(data) ~= "table" then
            finish({
                hasData = false,
                error = _("响应数据无效"),
            })
            return
        end

        local perDay = data.perDay or {}
        local selected = ""
        local ym = data.initialYm or os.date("%Y-%m")
        local days = {}
        for day in pairs(perDay) do
            table.insert(days, day)
        end
        table.sort(days)
        if #days > 0 then
            selected = days[#days]
            local yy, mm = selected:match("^(%d%d%d%d)%-(%d%d)")
            if yy and mm then
                ym = yy .. "-" .. mm
            end
        end

        finish({
            hasData = not not data.hasData,
            initialYm = data.initialYm,
            readingActivity = data.readingActivity or {},
            perDay = perDay,
            ym = ym,
            selected = selected,
        })
    end

    UIManager:scheduleIn(0, function()
        local ok, err = pcall(run)
        if not ok then
            logger.err("book insight fetch crashed:", err)
            finish({
                hasData = false,
                error = tostring(err),
            })
        end
    end)
end

return Insight
