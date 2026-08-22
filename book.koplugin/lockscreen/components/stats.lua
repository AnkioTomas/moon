--[[--
主体：书籍信息 + 阅读统计（进度 / 时长 + 近 7 日柱图）。仅宽屏。

书籍头部复用 BookInfo.hero；柱图仍走 Chart.appendBars（锁屏 DSL）。

@module koplugin.book.lockscreen.components.stats
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Current = require("lockscreen.components.current")
local Chart = require("ui.components.chart")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "stats",
    label = _("阅读统计"),
    supports_narrow = false,
    live = true,
    -- 统计信息密度高，不需要占满大部分屏幕。
    preferred_height = 0.56,
}

local BookInfo

--- 延迟加载桌面同源组件。
local function ensureUI()
    if BookInfo then return end
    BookInfo = require("ui.components.bookinfo")
end

--- 统计主体展示书籍信息、当前进度、累计时长和近 7 日柱图。
---@param rect table
---@return table[]
function M.blocks(rect)
    local book = Current.book(true)
    if not book then
        return U.emptyBlocks(rect, _("当前阅读"), _("当前没有正在阅读的书籍"))
    end
    ensureUI()
    local buckets = book.buckets or {}
    local week_seconds = 0
    for _, slot in ipairs(buckets) do
        week_seconds = week_seconds + (slot.seconds or 0)
    end
    local day_avg = week_seconds / math.max(1, #buckets)
    local chapter = U.chapterLine(book)
    local subtitle = chapter ~= "" and (_("章节") .. " · " .. chapter) or nil
    local hero, hero_h = BookInfo.hero(nil, nil, book, {
        width = rect.w,
        pad = rect.pad,
        subtitle = subtitle,
        show_progress = false,
    })

    local inner_x, inner_w = rect.text_x, rect.text_w
    local card_y, card_h = rect.y, rect.h
    local pad = rect.pad
    local divider_y = rect.y + hero_h
    local metric_y = divider_y + pad
    local pct, page_line = U.progress(book)
    -- 统计区只保留百分比和累计时长，不再绘制中间的进度轨道。
    local page_line_y = metric_y + 88
    local page_line_height = 24
    local metric_bottom = page_line_y + page_line_height
    local separator_y = metric_bottom + 10
    local chart_header_y = separator_y + 18
    local chart_y = chart_header_y + 34
    local chart_bottom = card_y + card_h - pad - 24
    local available_chart_h = math.max(1, chart_bottom - chart_y)
    local chart_h = math.min(
        math.floor(card_h * 0.28),
        available_chart_h
    )

    local blocks = {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            kind = "widget", role = "hero",
            widget = hero, x = rect.x, y = rect.y, width = rect.w, height = hero_h,
        },
        {
            kind = "rule", x = inner_x, y = divider_y,
            width = inner_w, height = 8, color = U.SURFACE,
        },
        {
            text = string.format("%.0f%%", pct),
            x = inner_x, y = metric_y,
            width = inner_w * 0.42, size = 40, bold = true, box = false,
        },
        {
            text = _("累计阅读"),
            x = math.floor(inner_x + inner_w * 0.45), y = metric_y + 4,
            width = math.floor(inner_w * 0.55), size = 13, align = "right", box = false, color = U.MUTED,
        },
        {
            text = U.duration(book.total_seconds),
            x = math.floor(inner_x + inner_w * 0.45), y = metric_y + 31,
            width = math.floor(inner_w * 0.55), size = 18, bold = true, align = "right", box = false,
        },
        {
            text = page_line,
            x = inner_x, y = page_line_y,
            width = inner_w, size = 14, box = false, color = U.DIM,
        },
        {
            kind = "rule", x = inner_x, y = separator_y,
            width = inner_w, height = 8, color = U.SURFACE,
        },
        {
            text = _("最近 7 天"),
            x = inner_x, y = chart_header_y,
            width = inner_w * 0.5, size = 15, bold = true, box = false,
        },
        {
            text = _("日均") .. " " .. U.duration(day_avg),
            x = math.floor(inner_x + inner_w * 0.45), y = chart_header_y,
            width = math.floor(inner_w * 0.55), size = 14, align = "right", box = false, color = U.MUTED,
        },
    }
    Chart.appendBars(blocks, {
        points = buckets,
        value_key = "seconds",
        x = inner_x,
        y = chart_y,
        width = inner_w,
        height = chart_h,
        label_color = U.DIM,
        label_mode = "all",
        -- 统计只有 7 根柱，放宽柱宽上限，让图表铺满左右内容边界。
        bar_cap_ratio = 0.20,
    })

    return blocks
end

return M
