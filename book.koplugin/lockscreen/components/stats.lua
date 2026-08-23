--[[--
主体：书籍信息 + 阅读统计（进度 / 时长 + 近 7 日柱图）。仅宽屏。

头部复用 BookInfo.hero / progressRow；柱图走 Chart.appendBars。
布局按内容自上而下堆叠，边距和段间距故意留足，避免贴边。

@module koplugin.book.lockscreen.components.stats
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Current = require("lockscreen.components.current")
local Chart = require("ui.components.chart")
local Layout = require("lockscreen.layout")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "stats",
    label = _("阅读统计"),
    supports_narrow = false,
    live = true,
    -- 柱图占屏高 30%，卡片整体需要更高的定位预算。
    preferred_height = 0.72,
}

local BookInfo

--- 延迟加载桌面同源组件。
local function ensureUI()
    if BookInfo then return end
    BookInfo = require("ui.components.bookinfo")
end

--- 统计主体：hero → 进度条 → 时长/页数 → 近 7 日柱图。
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
    local pct, page_line = U.progress(book)
    local chapter = U.chapterLine(book)
    local subtitle = chapter ~= "" and (_("章节") .. " · " .. chapter) or nil

    -- 锁屏统计卡要呼吸感：边距和段间距都比桌面 hero 更松。
    local pad = math.max(24, math.min(rect.pad or 24, 32))
    local inset_v = 24
    local gap = 22
    local inner_x = rect.x + pad
    local inner_w = math.max(1, rect.w - pad * 2)

    local hero, hero_h = BookInfo.hero(nil, nil, book, {
        width = rect.w,
        pad = pad,
        subtitle = subtitle,
        show_progress = false,
        sync = true,
    })
    local progress, progress_h = BookInfo.progressRow(inner_w, pct)

    local _screen_w, screen_h = Layout.portraitSize()
    local chart_h = math.max(96, math.floor(screen_h * 0.30))
    local chart_label_h = 24
    local meta_row_h = 36
    local meta_gap = 12
    local meta_h = meta_row_h * 2 + meta_gap
    local chart_header_h = 26
    local after_progress = 18
    local after_rule = 18
    local before_chart = 14

    local card_h = inset_v
        + hero_h + gap
        + progress_h + after_progress
        + meta_h + gap
        + 1 + after_rule
        + chart_header_h + before_chart
        + chart_h + chart_label_h
        + inset_v
    local card_y = rect.y + math.max(0, math.floor((rect.h - card_h) / 2))

    local y = card_y + inset_v
    local hero_y = y
    y = y + hero_h + gap
    local progress_y = y
    y = y + progress_h + after_progress
    local meta_y = y
    y = y + meta_h + gap
    local rule_y = y
    y = y + 1 + after_rule
    local chart_header_y = y
    y = y + chart_header_h + before_chart
    local chart_y = y

    local half = math.floor(inner_w * 0.5)
    local label_w = math.floor(inner_w * 0.40)
    local value_gap = 16
    local value_x = inner_x + label_w + value_gap
    local value_w = math.max(1, inner_w - label_w - value_gap)
    -- 小号 label 相对大号数值略下移，光学对齐。
    local label_dy = 4
    local blocks = {
        {
            kind = "panel", x = rect.x, y = card_y, width = rect.w, height = card_h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            kind = "widget", role = "hero",
            widget = hero, x = rect.x, y = hero_y, width = rect.w, height = hero_h,
        },
        {
            kind = "widget", role = "progress",
            widget = progress, x = inner_x, y = progress_y, width = inner_w, height = progress_h,
        },
        {
            text = _("累计阅读"),
            x = inner_x, y = meta_y + label_dy,
            width = label_w, size = 14, box = false, color = U.MUTED,
        },
        {
            text = U.duration(book.total_seconds),
            x = value_x, y = meta_y,
            width = value_w, size = 20, bold = true, align = "right", box = false,
        },
        {
            text = _("页数"),
            x = inner_x, y = meta_y + meta_row_h + meta_gap + label_dy,
            width = label_w, size = 14, box = false, color = U.MUTED,
        },
        {
            text = page_line,
            x = value_x, y = meta_y + meta_row_h + meta_gap,
            width = value_w, size = 18, align = "right", box = false,
        },
        {
            kind = "rule", x = inner_x, y = rule_y,
            width = inner_w, height = 1, color = U.RULE,
        },
        {
            text = _("最近 7 天"),
            x = inner_x, y = chart_header_y,
            width = half, size = 15, bold = true, box = false,
        },
        {
            text = _("日均") .. " " .. U.duration(day_avg),
            x = inner_x + half, y = chart_header_y,
            width = half, size = 14, align = "right", box = false, color = U.MUTED,
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
        bar_cap_ratio = 0.18,
    })

    return blocks
end

return M
