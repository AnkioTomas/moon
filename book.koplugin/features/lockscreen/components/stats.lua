--[[--
主体：书籍信息 + 阅读统计（进度 / 时长 + 近 7 日柱图）。仅宽屏。

书卡（封面 + 书名 + 进度）→ 三格数据（累计 / 最近 7 天 / 日均）→ 近 7 日柱图。
卡片高度按内容算、在面板里垂直居中；柱图限高，不拿剩余空间把一根柱子撑满半屏。

@module koplugin.book.features.lockscreen.components.stats
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Current = require("features.lockscreen.components.current")
local Chart = require("features.lockscreen.components.chart")
local U = require("features.lockscreen.components.util")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "stats",
    label = _("阅读统计"),
    supports_narrow = false,
    preferred_height = 0.88,
}

M.cache_key = Current.cache_key

-- 柱下日期标签占位（含与基线的 5px 间距）。
local CHART_LABEL_H = 18

--- 柱顶数值：满 1 小时按小时保留一位小数，否则按分钟。
---@param seconds number
---@return string
local function barValue(seconds)
    if seconds >= 3600 then
        return T(_("%1小时"), string.format("%g", math.floor(seconds / 360 + 0.5) / 10))
    end
    return T(_("%1分钟"), math.max(1, math.floor(seconds / 60 + 0.5)))
end

--- 统计主体：书卡 → 三格数据 → 近 7 日柱图。块先按卡片顶 y=0 排，最后整体下移。
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

    local pad = math.max(24, math.min(rect.pad or 24, 32))
    local inner_x = rect.x + pad
    local inner_w = math.max(1, rect.w - pad * 2)
    local line_color = Blitbuffer.COLOR_LIGHT_GRAY
    local blocks = {}
    local function push(list)
        for _idx, block in ipairs(list) do blocks[#blocks + 1] = block end
    end

    -- 书卡：封面左，右侧书名 / 作者 / 章节，下接进度条与「百分比 · 页数」。
    local cover_w = math.floor(rect.w * 0.2)
    local cover_h = math.floor(cover_w * 1.45)
    local y = pad
    blocks[1] = U.coverBlock(book, inner_x, y, cover_w, cover_h)
    local text_x = inner_x + cover_w + math.floor(pad * 0.6)
    local text_w = math.max(1, inner_x + inner_w - text_x)
    local head, head_bottom = U.bookHead(book, subtitle, text_x, y, text_w)
    push(head)
    local bar_y = head_bottom + 8
    local bar, bar_h = U.progressBlocks(text_x, bar_y, text_w, pct)
    push(bar)
    local caption_y = bar_y + bar_h + 6
    local half = math.floor(text_w / 2)
    push({
        { text = U.percentText(pct), x = text_x, y = caption_y, width = half,
          size = 13, bold = true, box = false },
        { text = page_line, x = text_x + half, y = caption_y, width = text_w - half,
          size = 13, align = "right", box = false, color = U.MUTED },
    })
    local caption_bottom = caption_y + 18
    y = y + math.max(cover_h, caption_bottom - y) + pad

    blocks[#blocks + 1] = { kind = "rule", x = inner_x, y = y, width = inner_w, height = 1, color = line_color }
    y = y + 1 + pad

    -- 三格数据：数值大字居中、说明小字在下，格间细竖线。
    local kpis = {
        { U.duration(book.total_seconds), _("累计阅读") },
        { U.duration(week_seconds), _("最近 7 天") },
        { U.duration(day_avg), _("日均") },
    }
    local col_w = math.floor(inner_w / #kpis)
    local kpi_h = 0
    for i, kpi in ipairs(kpis) do
        local col_x = inner_x + (i - 1) * col_w
        local value, value_h = U.fitLine(kpi[1], col_x + 4, y, col_w - 8, 20, 13, true)
        value.align = "center"
        local label, label_h = U.fitLine(kpi[2], col_x + 4, y + value_h + 4, col_w - 8, 13, 11)
        label.align, label.color = "center", U.MUTED
        push({ value, label })
        kpi_h = math.max(kpi_h, value_h + 4 + label_h)
    end
    for i = 2, #kpis do
        blocks[#blocks + 1] = {
            kind = "rule", x = inner_x + (i - 1) * col_w, y = y + 2,
            width = 1, height = math.max(1, kpi_h - 4), color = line_color,
        }
    end
    y = y + kpi_h + pad

    -- 柱图限高：卡片放得下时取内容宽的 0.38，放不下才压缩。
    local fixed_h = y + CHART_LABEL_H + pad
    local chart_h = math.max(0, math.min(math.floor(inner_w * 0.38), rect.h - fixed_h))
    local chart_y = y
    Chart.appendBars(blocks, {
        points = buckets,
        value_key = "seconds",
        x = inner_x,
        y = chart_y,
        width = inner_w,
        height = chart_h,
        bar_cap_ratio = 0.09,
        value_label = barValue,
        highlight_last = true,
    })

    local card_h = fixed_h + chart_h
    local card_y = rect.y + math.max(0, math.floor((rect.h - card_h) / 2))
    for _idx, block in ipairs(blocks) do block.y = block.y + card_y end
    table.insert(blocks, 1, {
        kind = "panel", x = rect.x, y = card_y, width = rect.w, height = card_h,
        radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
    })
    return blocks
end

return M
