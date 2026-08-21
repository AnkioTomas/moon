--[[--
阅读统计锁屏。

三种布局（lock_screen_reading_mode）：
  simple   — 顶部条：章节 / 进度 / 剩余
  bookmark — 居中书签卡（默认，含近 7 日柱图）
  cover    — 左侧多卡：章节、高亮、进度

背景由 Background 统一提供（含最近书籍封面）。

@module koplugin.book.lockscreen.styles.reading
--]]

local Background = require("lockscreen.background")
local Context = require("lockscreen.context")
local Chart = require("ui.components.chart")
local Paths = require("utils.paths")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local T = require("ffi/util").template

local M = { id = "reading", label = _("阅读统计"), local_render = true }

local MUTED = Blitbuffer.COLOR_GRAY_3
local DIM = Blitbuffer.COLOR_GRAY_4

---@return string simple/bookmark/cover
local function readingMode()
    local ok, settings = pcall(function()
        return require("utils.settings").get()
    end)
    if ok and type(settings) == "table" then
        return settings.lock_screen_reading_mode or "bookmark"
    end
    return "bookmark"
end

---@return string
function M.path()
    return Paths.screensaverDir() .. "/reading.png"
end

---@return string 含布局后缀，切换模式即失效缓存
function M.dayKey()
    return require("lockscreen.styles.base").dayKey() .. ":" .. readingMode()
end

---@param seconds number|nil
---@return string
local function duration(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return minutes >= 60 and T(_("%1 小时 %2 分钟"), math.floor(minutes / 60), minutes % 60)
        or T(_("%1 分钟"), minutes)
end

---@param book table
---@return string
local function chapterLine(book)
    if book.chapter_title and book.chapter_title ~= "" then
        return book.chapter_title
    end
    if book.chapter_count and book.chapter_count > 0 then
        return T(_("第 %1 / %2 章"), book.chapter_idx or 1, book.chapter_count)
    end
    return _("阅读中")
end

---@param book table
---@return string
local function remainingLine(book)
    if book.remaining_pages and book.remaining_pages > 0 then
        return T(_("剩余 %1 页"), book.remaining_pages)
    end
    return T(_("剩余 %1%%"), math.floor(book.remaining_percent or 0))
end

---@param book table
---@return string
local function progressLine(book)
    if book.total_pages > 0 then
        return T(_("%1 / %2 页 · %3%%"), book.page, book.total_pages, math.floor(book.percent))
    end
    return string.format("%.0f%%", book.percent)
end

--- 空态卡片。
---@param w number
---@param h number
---@return table[]
local function emptyBlocks(w, h)
    local margin = math.max(16, math.floor(w * 0.055))
    local radius = math.max(8, math.floor(w * 0.02))
    local pad = math.max(14, math.floor(w * 0.045))
    local card_w = w - margin * 2
    local card_h = math.floor(h * 0.42)
    local card_y = math.floor((h - card_h) / 2)
    local inner_x = margin + pad
    local inner_w = card_w - pad * 2
    return {
        {
            kind = "panel", x = margin, y = card_y, width = card_w, height = card_h,
            radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = _("阅读统计"), x = inner_x, y = card_y + pad,
            width = inner_w, size = 18, box = false, color = MUTED,
        },
        {
            kind = "rule", x = inner_x, y = card_y + pad + 28,
            width = inner_w, height = 1,
        },
        {
            text = _("当前没有正在阅读的书籍"),
            x = inner_x, y = card_y + math.floor(card_h * 0.48),
            width = inner_w, size = 20, align = "center", box = false, color = MUTED,
        },
    }
end

--- 简洁模式：顶部信息条。
---@param book table
---@param w number
---@param h number
---@return table[]
local function layoutSimple(book, w, h)
    local margin = math.max(14, math.floor(w * 0.04))
    local radius = math.max(8, math.floor(w * 0.02))
    local pad = math.max(12, math.floor(w * 0.035))
    local card_w = w - margin * 2
    local card_h = math.max(110, math.floor(h * 0.22))
    local card_y = margin
    local inner_x = margin + pad
    local inner_w = card_w - pad * 2
    return {
        {
            kind = "panel", x = margin, y = card_y, width = card_w, height = card_h,
            radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = chapterLine(book), x = inner_x, y = card_y + pad,
            width = inner_w, size = 20, bold = true, box = false,
        },
        {
            text = progressLine(book), x = inner_x, y = card_y + pad + math.floor(card_h * 0.32),
            width = inner_w * 0.55, size = 15, box = false, color = MUTED,
        },
        {
            text = remainingLine(book),
            x = math.floor(inner_x + inner_w * 0.45), y = card_y + pad + math.floor(card_h * 0.32),
            width = math.floor(inner_w * 0.55), size = 15, align = "right", box = false, color = MUTED,
        },
        {
            kind = "bar", x = inner_x, y = card_y + card_h - pad - 10,
            width = inner_w, height = 8, value = book.percent / 100,
        },
    }
end

--- 书签模式：居中大卡 + 近 7 日柱图（现行默认）。
---@param book table
---@param w number
---@param h number
---@return table[]
local function layoutBookmark(book, w, h)
    local margin = math.max(16, math.floor(w * 0.055))
    local radius = math.max(8, math.floor(w * 0.02))
    local pad = math.max(14, math.floor(w * 0.045))
    local card_x = margin
    local card_w = w - margin * 2
    local inner_x = card_x + pad
    local inner_w = card_w - pad * 2
    local position = book.total_pages > 0
        and T(_("%1 / %2 页"), book.page, book.total_pages) or ""
    local chapter = chapterLine(book)
    local meta = table.concat({ position, remainingLine(book) }, "  ·  ")
    local buckets = book.buckets or {}
    local week_seconds = 0
    for _, slot in ipairs(buckets) do
        week_seconds = week_seconds + (slot.seconds or 0)
    end
    local day_avg = week_seconds / math.max(1, #buckets)
    local card_h = math.floor(h * 0.90)
    local card_y = math.floor((h - card_h) / 2)
    local blocks = {
        {
            kind = "panel", x = card_x, y = card_y, width = card_w, height = card_h,
            radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = _("阅读统计"), x = inner_x, y = card_y + pad,
            width = inner_w, size = 16, box = false, color = MUTED,
        },
        {
            kind = "rule", x = inner_x, y = card_y + pad + 26,
            width = inner_w, height = 1,
        },
        {
            text = book.title, x = inner_x, y = math.floor(card_y + card_h * 0.10),
            width = inner_w, size = 24, bold = true, box = false,
        },
        {
            text = book.authors ~= "" and book.authors or chapter,
            x = inner_x, y = math.floor(card_y + card_h * 0.20),
            width = inner_w, size = 15, box = false, color = MUTED,
        },
        {
            text = string.format("%.0f%%", book.percent),
            x = inner_x, y = math.floor(card_y + card_h * 0.28),
            width = inner_w * 0.42, size = 40, bold = true, box = false,
        },
        {
            text = _("累计阅读"),
            x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.29),
            width = math.floor(inner_w * 0.55), size = 13, align = "right", box = false, color = MUTED,
        },
        {
            text = duration(book.total_seconds),
            x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.34),
            width = math.floor(inner_w * 0.55), size = 18, bold = true, align = "right", box = false,
        },
        {
            kind = "bar", x = inner_x, y = math.floor(card_y + card_h * 0.44),
            width = inner_w, height = 8, value = book.percent / 100,
        },
        {
            text = meta, x = inner_x, y = math.floor(card_y + card_h * 0.49),
            width = inner_w, size = 14, box = false, color = DIM,
        },
        {
            kind = "rule", x = inner_x, y = math.floor(card_y + card_h * 0.56),
            width = inner_w, height = 1,
        },
        {
            text = _("最近 7 天"),
            x = inner_x, y = math.floor(card_y + card_h * 0.59),
            width = inner_w * 0.5, size = 15, bold = true, box = false,
        },
        {
            text = _("日均") .. " " .. duration(day_avg),
            x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.59),
            width = math.floor(inner_w * 0.55), size = 14, align = "right", box = false, color = MUTED,
        },
    }
    Chart.appendBars(blocks, {
        points = buckets,
        value_key = "seconds",
        x = inner_x,
        y = math.floor(card_y + card_h * 0.68),
        width = inner_w,
        height = math.floor(card_h * 0.20),
        label_color = DIM,
        label_mode = "all",
    })
    return blocks
end

--- 封面模式：左侧叠卡（章节 / 高亮 / 进度）。
---@param book table
---@param w number
---@param h number
---@return table[]
local function layoutCover(book, w, h)
    local margin = math.max(14, math.floor(w * 0.04))
    local radius = math.max(8, math.floor(w * 0.02))
    local pad = math.max(12, math.floor(w * 0.032))
    local col_w = math.floor(w * 0.46)
    local gap = math.max(10, math.floor(h * 0.018))
    local y = margin
    local blocks = {}

    local function pushCard(title, body, sub, card_h)
        blocks[#blocks + 1] = {
            kind = "panel", x = margin, y = y, width = col_w, height = card_h,
            radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        }
        blocks[#blocks + 1] = {
            text = title, x = margin + pad, y = y + pad,
            width = col_w - pad * 2, size = 13, box = false, color = MUTED,
        }
        blocks[#blocks + 1] = {
            text = body, x = margin + pad, y = y + pad + math.floor(card_h * 0.28),
            width = col_w - pad * 2, size = 18, bold = true, box = false,
        }
        if sub and sub ~= "" then
            blocks[#blocks + 1] = {
                text = sub, x = margin + pad, y = y + card_h - pad - 18,
                width = col_w - pad * 2, size = 13, box = false, color = DIM,
            }
        end
        y = y + card_h + gap
    end

    local h1 = math.floor(h * 0.22)
    local h2 = math.floor(h * 0.34)
    local h3 = math.floor(h * 0.24)
    pushCard(_("章节"), chapterLine(book), book.title or "", h1)

    local highlights = book.highlights or {}
    local highlight_text = highlights[1] or _("暂无高亮")
    if #highlight_text > 60 then
        highlight_text = highlight_text:sub(1, 57) .. "…"
    end
    local highlight_sub = #highlights > 1
        and T(_("另有 %1 条"), #highlights - 1) or ""
    pushCard(_("高亮"), highlight_text, highlight_sub, h2)

    pushCard(
        _("进度"),
        string.format("%.0f%%", book.percent),
        progressLine(book) .. "  ·  " .. remainingLine(book),
        h3
    )

    -- 右侧轻量书名/作者，避免整屏只剩左栏
    local right_x = margin + col_w + gap
    local right_w = w - right_x - margin
    if right_w > 40 then
        blocks[#blocks + 1] = {
            text = book.authors or "",
            x = right_x, y = h - margin - 40,
            width = right_w, size = 14, align = "right", box = false, color = MUTED,
        }
        blocks[#blocks + 1] = {
            text = book.title or "",
            x = right_x, y = h - margin - 70,
            width = right_w, size = 16, bold = true, align = "right", box = false,
        }
    end
    return blocks
end

---@param cb fun(ok: boolean, err: any)
---@return table|nil
function M.fetch(cb)
    return Background.ensure(function(bg)
        local Render = require("lockscreen.render")
        local w, h = Render.size()
        local book = Context.currentBook()
        local blocks
        if not book then
            blocks = emptyBlocks(w, h)
        else
            local mode = readingMode()
            if mode == "simple" then
                blocks = layoutSimple(book, w, h)
            elseif mode == "cover" then
                blocks = layoutCover(book, w, h)
            else
                blocks = layoutBookmark(book, w, h)
            end
        end
        local ok, err = Render.write(M.path(), bg, blocks)
        cb(ok, err)
    end)
end

return M
