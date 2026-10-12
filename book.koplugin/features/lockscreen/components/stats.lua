--[[--
主体：书籍信息 + 阅读统计（进度 / 时长 + 近 7 日柱图）。仅宽屏。

头部用封面和文字块；柱图走 features.lockscreen.components.chart。
布局按内容自上而下堆叠，边距和段间距故意留足，避免贴边。

@module koplugin.book.features.lockscreen.components.stats
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Current = require("features.lockscreen.components.current")
local Chart = require("features.lockscreen.components.chart")
local U = require("features.lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "stats",
    label = _("阅读统计"),
    supports_narrow = false,
    preferred_height = 0.88,
}

M.cache_key = Current.cache_key

--- 统计主体：书卡 → 进度条 → 时长/页数 → 近 7 日柱图。
---@param rect table
---@return table[]
function M.blocks(rect)
    local book = Current.book(true)
    if not book then
        return U.emptyBlocks(rect, _("当前阅读"), _("当前没有正在阅读的书籍"))
    end

    local buckets = book.buckets or {}
    local week_seconds = 0
    for _idx, slot in ipairs(buckets) do
        week_seconds = week_seconds + (slot.seconds or 0)
    end
    local day_avg = week_seconds / math.max(1, #buckets)
    local pct, page_line = U.progress(book)
    local subtitle
    if (book.chapter_title and book.chapter_title ~= "")
        or (book.chapter_count and book.chapter_count > 0) then
        subtitle = _("章节") .. " · " .. U.chapterLine(book)
    end

    -- 间距与图表高度都从面板预算中计算，不能再拿全屏高度硬撑卡片。
    local pad = math.max(24, math.min(rect.pad or 24, 32))
    local inset_v = math.max(10, math.floor(rect.h * 0.03))
    local gap = math.max(8, math.floor(rect.h * 0.025))
    local inner_x = rect.x + pad
    local inner_w = math.max(1, rect.w - pad * 2)

    local cover_w = math.floor(rect.w * 0.18)
    local hero_h = math.floor(cover_w * 1.45)
    local progress_h = 8

    local chart_label_h = 18
    local meta_row_h = math.max(24, math.floor(rect.h * 0.055))
    local meta_gap = 8
    local meta_h = meta_row_h * 2 + meta_gap
    local chart_header_h = 22
    local after_progress = math.max(8, math.floor(rect.h * 0.02))
    local after_rule = math.max(8, math.floor(rect.h * 0.02))
    local before_chart = 8

    local fixed_h = inset_v
        + hero_h + gap
        + progress_h + after_progress
        + meta_h + gap
        + 1 + after_rule
        + chart_header_h + before_chart
        + chart_label_h
        + inset_v
    local chart_h = math.max(0, rect.h - fixed_h)

    local y = rect.y + inset_v
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
    local text_x = inner_x + cover_w + 12
    local text_w = math.max(1, inner_x + inner_w - text_x)
    local blocks = {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        U.coverBlock(book, inner_x, hero_y, cover_w, hero_h),
    }
    for _idx, block in ipairs((U.bookHead(book, subtitle, text_x, hero_y, text_w))) do
        blocks[#blocks + 1] = block
    end
    local progress = U.progressBlocks(inner_x, progress_y, inner_w, pct)
    for _idx, block in ipairs(progress) do blocks[#blocks + 1] = block end
    local tail = {
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
    for _idx, block in ipairs(tail) do blocks[#blocks + 1] = block end
    Chart.appendBars(blocks, {
        points = buckets,
        value_key = "seconds",
        x = inner_x,
        y = chart_y,
        width = inner_w,
        height = chart_h,
        bar_cap_ratio = 0.18,
    })

    return blocks
end

return M
