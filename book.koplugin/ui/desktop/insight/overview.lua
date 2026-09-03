--[[--
统计页第 1 页：总览 KPI 与月历。

@module koplugin.book.ui.desktop.insight.overview
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BookInfo = require("ui.components.bookinfo")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local Overview = {}
local DOW = { _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六") }

--- 年月字符串按月偏移。
---@param ym string YYYY-MM。
---@param delta number 月份偏移量。
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

--- 生成年月显示文案。
---@param ym string YYYY-MM。
---@return string
local function ymLabel(ym)
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    if not y then return ym end
    return T(_("%1年%2月"), y, tonumber(m))
end

--- 解析日历格对应的真实日期。
---@param y number 当前年份。
---@param m number 当前月份。
---@param day_num number 日历格日号。
---@param days_in_month number 当前月天数。
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

--- 构建总时长英雄区。
---@param state table 统计状态。
---@param width number 内容宽度。
---@return table
local function buildHero(state, width)
    local total_obj = state.total or {}
    local total = total_obj.total_text
    if state.error or not state.has_data or not total_obj.has_data or not total or total == "" then
        total = "—"
    end
    local hero_h = UI.sz(96)
    return CenterContainer:new{
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
            UI.mutedText(_("总阅读时长"), width, 13),
        },
    }
end

--- 构建次级 KPI 三列。
---@param state table 统计状态。
---@param width number 内容宽度。
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
        local value = item[2]
        if value == nil or value == "" then value = "—" end
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = row_h },
            VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text = tostring(value),
                    face = UI.face("cfont", 15),
                    max_width = cell_w - UI.sz(4),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
                VerticalSpan:new{ width = UI.sz(4) },
                UI.mutedText(item[1], cell_w - UI.sz(4), 12),
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

--- 构建日历单格。
---@param size number 单格边长。
---@param day_num number 显示日号。
---@param has_read boolean 是否有阅读记录。
---@param out_month boolean 是否属于相邻月份。
---@param selected boolean 是否选中。
---@param on_tap fun()|nil 点击回调。
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

--- 构建日历月份导航按钮。
---@param label string 按钮文字。
---@param width number 按钮宽度。
---@param height number 按钮高度。
---@param on_tap fun()|nil 点击回调。
---@return table
local function navBtn(label, width, height, on_tap)
    local tap = BookInfo.tappable(width, height, on_tap)
    tap[1] = CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        TextWidget:new{
            text = label,
            face = UI.face("cfont", 22),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    return tap
end

--- 构建月历网格，并按剩余高度收缩日期格。
---@param desktop table 桌面实例。
---@param state table 统计状态。
---@param width number 内容宽度。
---@param max_height number|nil 日历最大高度。
---@return table
local function buildCalendar(desktop, state, width, max_height)
    local per_day = (state.calendar and state.calendar.days) or {}
    local ym = state.ym or (state.calendar and state.calendar.initial_ym) or os.date("%Y-%m")
    local selected = state.selected or ""
    local y, m = ym:match("^(%d%d%d%d)%-(%d%d)$")
    y, m = tonumber(y), tonumber(m)
    if not y or not m then
        y, m = tonumber(os.date("%Y")), tonumber(os.date("%m"))
        ym = string.format("%04d-%02d", y, m)
    end

    local nav_h, button_w = UI.sz(36), UI.sz(48)
    local label_w = math.max(1, width - button_w * 2)
    local nav = HorizontalGroup:new{
        align = "center",
        navBtn("‹", button_w, nav_h, function()
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
        navBtn("›", button_w, nav_h, function()
            state.ym = shiftYm(ym, 1)
            desktop:rebuild()
        end),
    }

    local gap = UI.sz(2)
    local col_w = math.floor((width - gap * 6) / 7)
    local size = math.min(col_w, UI.sz(36))
    local first_wday = tonumber(os.date("%w", os.time{ year = y, month = m, day = 1 })) or 0
    local days_in_month = tonumber(os.date("%d", os.time{ year = y, month = m + 1, day = 0 })) or 30
    local total = math.ceil((first_wday + days_in_month) / 7) * 7
    local rows = math.ceil(total / 7)
    if max_height then
        local fixed_h = nav_h + UI.sz(4) + UI.sz(20) + UI.sz(2) + gap * (rows - 1)
        size = math.min(size, math.floor((max_height - fixed_h) / rows))
    end
    size = math.max(1, size)

    local dow_row = HorizontalGroup:new{ align = "center" }
    for i, name in ipairs(DOW) do
        if i > 1 then table.insert(dow_row, HorizontalSpan:new{ width = gap }) end
        table.insert(dow_row, CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = UI.sz(20) },
            UI.mutedText(name, col_w, 11),
        })
    end

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
        local cy, cm, cd, out = resolveDay(y, m, start_day + i, days_in_month)
        local key = string.format("%04d-%02d-%02d", cy, cm, cd)
        local info = per_day[key]
        local seconds = info and (tonumber(info.duration_seconds) or 0) or 0
        local cell = calCell(size, cd, seconds > 0, out, key == selected, function()
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

--- 构建概览页。
---@param desktop table 桌面实例。
---@param state table 统计状态。
---@param width number 内容宽度。
---@param avail_h number 可用高度。
---@return table
function Overview.build(desktop, state, width, avail_h)
    local col = VerticalGroup:new{ align = "left", buildHero(state, width) }
    if state.error then
        table.insert(col, VerticalSpan:new{ width = UI.sz(12) })
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = width, h = UI.sz(24) },
            UI.mutedText(state.error, width),
        })
    elseif not state.has_data then
        table.insert(col, VerticalSpan:new{ width = UI.sz(12) })
        table.insert(col, CenterContainer:new{
            dimen = Geom:new{ w = width, h = UI.sz(40) },
            UI.mutedText(_("暂无阅读统计。上报后再查看。"), width),
        })
    else
        local hint = UI.mutedText(_("点选日期查看当日书单"), width)
        local fixed_h = UI.sz(96) + UI.sz(8) + UI.sz(48) + UI.sz(16) + UI.sz(8) + hint:getSize().h
        local calendar_h = math.max(1, avail_h - fixed_h)
        table.insert(col, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(col, buildSecondary(state, width))
        table.insert(col, VerticalSpan:new{ width = UI.sz(16) })
        table.insert(col, buildCalendar(desktop, state, width, calendar_h))
        table.insert(col, VerticalSpan:new{ width = UI.sz(8) })
        table.insert(col, hint)
    end
    return col
end

return Overview
