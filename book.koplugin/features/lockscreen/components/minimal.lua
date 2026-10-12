--[[--
主体：极简。大字日期 + 当前书高亮一句 + 贴底书名与进度条，不画卡片（配「无」背景即白底）。

日期由组合图按天缓存键保证当天正确；不画时钟：锁屏图在上次休眠时生成，时间必然过期。

@module koplugin.book.features.lockscreen.components.minimal
--]]

local Cards = require("features.lockscreen.components.cards")
local Current = require("features.lockscreen.components.current")
local Highlight = require("features.lockscreen.components.highlight")
local QuotePanel = require("features.lockscreen.components.quote_panel")
local Title = require("features.lockscreen.title")
local U = require("features.lockscreen.components.util")
local T = require("ffi/util").template
local _ = require("gettext")

local DOW = { _("日"), _("一"), _("二"), _("三"), _("四"), _("五"), _("六") }

local M = {
    id = "minimal",
    label = _("极简"),
    supports_position = false,
    full_screen = true,
    -- 含轮换高亮，每次锁屏都换一句：键每秒都变，等于不缓存。
    cache_key = os.time,
}

---@param rect table 全屏矩形
---@return table[]
function M.blocks(rect)
    local Render = require("features.lockscreen.render")
    local w, h = rect.w, rect.h
    local margin = math.floor(w * 0.1)
    local inner_w = w - margin * 2
    local gap = math.floor(w * 0.03)
    local now = os.date("*t")
    ---@cast now osdate

    local date_y = math.floor(h * 0.12)
    local weekday_y = date_y + Render.measureText("国", inner_w, 48, true) + gap
    local blocks = {
        {
            text = T(_("%1月%2日"), now.month, now.day), x = margin, y = date_y,
            width = inner_w, size = 48, bold = true, align = "center", box = false,
        },
        {
            text = _("星期") .. DOW[now.wday], x = margin, y = weekday_y,
            width = inner_w, size = 18, align = "center", box = false, color = U.MUTED,
        },
    }

    local quote, source = Highlight.next()
    if not quote then quote, source = U.FALLBACK_MESSAGE, _("默认句子") end
    local quote_y = math.floor(h * 0.36)
    local quote_text, quote_size, quote_h = QuotePanel.fit(quote, inner_w, 24, 18, math.floor(h * 0.3))
    blocks[#blocks + 1] = {
        text = quote_text, x = margin, y = quote_y, width = inner_w,
        size = quote_size, bold = true, align = "center", box = false,
    }
    blocks[#blocks + 1] = {
        text = "—— " .. (source or _("来自当前书籍高亮")), x = margin, y = quote_y + quote_h + gap * 2,
        width = inner_w, size = 16, align = "center", box = false, color = U.MUTED,
    }

    local book = Current.book(true)
    if not book then return blocks end
    local bar_h = 8
    local bar_y = h - margin - bar_h
    local meta_h = Render.measureText("国", inner_w, 14)
    local meta_y = bar_y - gap - meta_h
    local title_h = Render.measureText("国", inner_w, 18, true)
    local title_y = meta_y - math.floor(gap / 2) - title_h
    local title = Title.fitSingleLine(book.title, inner_w, 18, 16, Render.measureText)
    local remaining = Cards.remainingSeconds(book)
    local meta = _("今日阅读") .. " " .. U.duration(Cards.todaySeconds(book))
    if remaining then meta = meta .. " · " .. _("预计剩余") .. " " .. U.duration(remaining) end
    meta = Title.fitSingleLine(meta, inner_w, 14, 14, Render.measureText)
    blocks[#blocks + 1] = { kind = "rule", x = margin, y = title_y - gap * 2, width = inner_w, color = U.RULE }
    blocks[#blocks + 1] = {
        text = title, x = margin, y = title_y, width = inner_w, size = 18, bold = true, box = false,
    }
    blocks[#blocks + 1] = {
        text = meta, x = margin, y = meta_y, width = inner_w, size = 14, box = false, color = U.MUTED,
    }
    local bar = U.progressBlocks(margin, bar_y, inner_w, book.percent)
    for _idx, block in ipairs(bar) do blocks[#blocks + 1] = block end
    return blocks
end

return M
