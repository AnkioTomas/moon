--[[--
主体：单书阅读票根。仅宽屏。

票根只展示已有的当前书、进度与阅读统计；不伪造开始日期或“本次阅读”
这类当前数据模型无法可靠提供的信息。

@module koplugin.book.lockscreen.components.receipt
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Current = require("lockscreen.components.current")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "receipt",
    label = _("阅读票根"),
    supports_narrow = false,
    supports_position = false,
    preferred_height = 0.88,
}

local BookInfo

local function ensureUI()
    if not BookInfo then BookInfo = require("ui.components.bookinfo") end
end

--- 找出当前书今天的统计桶。
---@param book table
---@return table
local function todayStats(book)
    local today = os.date("%Y-%m-%d")
    for _, row in ipairs(book.buckets or {}) do
        if row.key == today then return row end
    end
    return { seconds = 0, pages = 0 }
end

--- 当前书、进度或今日统计变化时使同日组合缓存失效。
---@return string
function M.cache_key()
    local book = Current.book(true)
    if not book then return "none" end
    local today = todayStats(book)
    return table.concat({
        tostring(book.source_id or ""),
        tostring(book.stable_id or ""),
        tostring(book.percent or 0),
        tostring(book.page or 0),
        tostring(book.total_seconds or 0),
        tostring(today.seconds or 0),
        tostring(today.pages or 0),
    }, ":")
end

--- 根据已有累计时长与进度估算剩余时长；样本不足时不显示假精度。
---@param book table
---@return string
local function remaining(book)
    local percent = tonumber(book.percent) or 0
    local elapsed = tonumber(book.total_seconds) or 0
    if percent <= 0 or elapsed <= 0 then return _("暂无估算") end
    return U.duration(elapsed * (100 - math.min(percent, 100)) / percent)
end

--- 追加票据式虚线。
---@param blocks table[]
---@param x number
---@param y number
---@param width number
local function appendDashes(blocks, x, y, width)
    local dash, gap = 7, 5
    local right = x + width
    while x < right do
        blocks[#blocks + 1] = {
            kind = "rule", x = x, y = y, width = math.min(dash, right - x),
            height = 1, color = U.DIM,
        }
        x = x + dash + gap
    end
end

--- 在票面上下打齿孔，并在撕线两端切出半圆缺口。
---@param blocks table[]
---@param rect table
---@param tear_y number
local function appendCutouts(blocks, rect, tear_y)
    local radius = math.max(7, math.floor(rect.pad * 0.45))
    local step = radius * 3
    local left, right = rect.x, rect.x + rect.w
    local center = left + step
    while center <= right - step do
        blocks[#blocks + 1] = {
            kind = "cutout_circle", x = center, y = rect.y, radius = radius,
        }
        blocks[#blocks + 1] = {
            kind = "cutout_circle", x = center, y = rect.y + rect.h, radius = radius,
        }
        center = center + step
    end
    local tear_radius = math.floor(radius * 1.5)
    blocks[#blocks + 1] = {
        kind = "cutout_circle", x = left, y = tear_y, radius = tear_radius,
    }
    blocks[#blocks + 1] = {
        kind = "cutout_circle", x = right, y = tear_y, radius = tear_radius,
    }
end

--- 用稳定书籍身份生成纯装饰条码，不冒充可扫描编码。
---@param blocks table[]
---@param book table
---@param x number
---@param y number
---@param width number
---@param height number
local function appendBarcode(blocks, book, x, y, width, height)
    local seed = tostring(book.source_id or "") .. ":" .. tostring(book.stable_id or "")
    if seed == ":" then seed = tostring(book.title or "moon") end
    local right, i = x + width, 1
    while x < right do
        local byte = seed:byte((i - 1) % #seed + 1) or 1
        local bar = 1 + byte % 3
        if i % 3 ~= 0 then
            blocks[#blocks + 1] = {
                kind = "vbar", x = x, y = y, width = math.min(bar, right - x),
                height = height, value = 1, color = Blitbuffer.COLOR_BLACK,
            }
        end
        x = x + bar + 1 + byte % 2
        i = i + 1
    end
end

--- 阅读票根：日期 → 当前书 → 进度/时长 → 今日摘要 → 装饰条码。
---@param rect table
---@return table[]
function M.blocks(rect)
    local book = Current.book(true)
    if not book then
        return U.emptyBlocks(rect, _("阅读票根"), _("当前没有正在阅读的书籍"))
    end
    ensureUI()

    local today = todayStats(book)
    local x, width = rect.text_x, rect.text_w
    local y, height = rect.y, rect.h
    local pad = rect.pad
    local percent, page_line = U.progress(book)
    local cover_h = math.floor(height * 0.27)
    local cover_w = math.floor(cover_h / 1.5)
    local cover_x = x + width - cover_w
    local cover_y = y + math.floor(height * 0.195)
    local info_w = math.max(1, cover_x - x - pad)
    local cover = select(1, BookInfo.cover(nil, nil, book, cover_w, cover_h, {
        sync = true,
        shadow = false,
    }))
    local blocks = {
        {
            kind = "panel", x = rect.x, y = y, width = rect.w, height = height,
            radius = 2, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = _("阅读票根"), x = x, y = y + pad,
            width = width, size = 14, bold = true, box = false, color = U.MUTED,
        },
        {
            text = "READ RECEIPT", x = x, y = y + math.floor(height * 0.065),
            width = width, size = 28, bold = true, box = false,
        },
        {
            text = os.date("NO.%Y%m%d"), x = x + math.floor(width * 0.55), y = y + pad,
            width = math.floor(width * 0.45), size = 13, align = "right",
            box = false, color = U.MUTED,
        },
        {
            text = _("今日阅读轨迹") .. "  ·  " .. os.date("%Y.%m.%d"),
            x = x, y = y + math.floor(height * 0.125),
            width = width, size = 14, box = false, color = U.MUTED,
        },
        { kind = "rule", x = x, y = y + math.floor(height * 0.17), width = width, height = 1, color = U.RULE },
        {
            text = _("当前阅读"), x = x, y = y + math.floor(height * 0.195),
            width = info_w, size = 14, bold = true, box = false,
        },
        {
            text = book.title or book.stable_id or "",
            x = x, y = y + math.floor(height * 0.235),
            width = info_w, size = 30, bold = true, box = false,
        },
        {
            text = book.authors or "", x = x, y = y + math.floor(height * 0.325),
            width = info_w, size = 15, box = false, color = U.MUTED,
        },
        {
            kind = "widget", widget = cover,
            x = cover_x, y = cover_y, width = cover_w, height = cover_h,
        },
        {
            text = _("阅读进度"), x = x, y = y + math.floor(height * 0.49),
            width = math.floor(width * 0.55), size = 14, box = false,
        },
        {
            text = string.format("%.0f%%", percent),
            x = x + math.floor(width * 0.55), y = y + math.floor(height * 0.49),
            width = math.floor(width * 0.45), size = 18, bold = true,
            align = "right", box = false,
        },
        {
            kind = "panel", x = x, y = y + math.floor(height * 0.535),
            width = width, height = 7, radius = 0, color = U.RULE,
        },
        {
            kind = "panel", x = x, y = y + math.floor(height * 0.535),
            width = math.floor(width * percent / 100), height = 7,
            radius = 0, color = Blitbuffer.COLOR_BLACK,
        },
        {
            text = page_line, x = x, y = y + math.floor(height * 0.56),
            width = math.floor(width * 0.5), size = 13, box = false, color = U.MUTED,
        },
        {
            text = _("预计剩余") .. "  " .. remaining(book),
            x = x + math.floor(width * 0.42), y = y + math.floor(height * 0.56),
            width = math.floor(width * 0.58), size = 13, align = "right",
            box = false, color = U.MUTED,
        },
    }

    appendDashes(blocks, x, y + math.floor(height * 0.625), width)
    blocks[#blocks + 1] = {
        text = _("今日摘要") .. "  SUMMARY", x = x, y = y + math.floor(height * 0.65),
        width = width, size = 19, bold = true, box = false,
    }
    blocks[#blocks + 1] = {
        kind = "rule", x = x, y = y + math.floor(height * 0.70),
        width = width, height = 1, color = U.RULE,
    }

    local half = math.floor(width / 2)
    local column_gap = math.max(12, math.floor(pad * 0.7))
    blocks[#blocks + 1] = {
        text = _("今日阅读页数"), x = x, y = y + math.floor(height * 0.725),
        width = half - column_gap, size = 13, box = false, color = U.MUTED,
    }
    blocks[#blocks + 1] = {
        text = tostring(tonumber(today.pages) or 0) .. " " .. _("页"),
        x = x, y = y + math.floor(height * 0.765),
        width = half - column_gap, size = 27, bold = true, box = false,
    }
    blocks[#blocks + 1] = {
        text = _("今日阅读时长"), x = x + half + column_gap, y = y + math.floor(height * 0.725),
        width = width - half - column_gap, size = 13, box = false, color = U.MUTED,
    }
    blocks[#blocks + 1] = {
        text = U.duration(today.seconds), x = x + half + column_gap, y = y + math.floor(height * 0.765),
        width = width - half - column_gap, size = 27, bold = true, box = false,
    }
    blocks[#blocks + 1] = {
        kind = "rule", x = x + half, y = y + math.floor(height * 0.72),
        width = 1, height = math.floor(height * 0.10), color = U.RULE,
    }

    appendDashes(blocks, x, y + math.floor(height * 0.835), width)
    appendBarcode(blocks, book, x, y + math.floor(height * 0.865), width, math.max(24, math.floor(height * 0.04)))
    blocks[#blocks + 1] = {
        text = _("阅读记录") .. "  ·  READING LOG  ·  " .. os.date("%Y%m%d"),
        x = x, y = y + math.floor(height * 0.92),
        width = width, size = 11, align = "center", box = false, color = U.MUTED,
    }
    appendCutouts(blocks, rect, y + math.floor(height * 0.625))
    return blocks
end

return M
