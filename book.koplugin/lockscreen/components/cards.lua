--[[--
锁屏卡片堆（胶囊 / 封面卡片主体共用）：书卡、进度卡、今日阅读 + 预计剩余。

不是主体，不进注册表。块先从 y=0 自上而下排，最后整体平移贴到屏幕底部。

@module koplugin.book.lockscreen.components.cards
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Current = require("lockscreen.components.current")
local Layout = require("lockscreen.layout")
local Title = require("lockscreen.title")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {}

local Render
local BookInfo

--- 延迟加载离屏测量与桌面同源组件，避免注册表 require 时拉进 Widget。
local function ensureUI()
    if Render then return end
    Render = require("lockscreen.render")
    BookInfo = require("ui.components.bookinfo")
end

--- 单行实际高度；字号随 DPI 缩放，不能写死像素。
---@param size number
---@param bold boolean|nil
---@return number
local function lineHeight(size, bold)
    return Render.measureText("国", 1000, size, bold)
end

--- 按本书累计时长与全书进度外推剩余时间，公式与阅读栏「剩余时间」一致。
---@param book table Current.book(true) 快照
---@return number|nil 未开读 / 已读完 / 无阅读记录时 nil
function M.remainingSeconds(book)
    local fraction = book.percent / 100
    if fraction <= 0 or fraction >= 1 or book.total_seconds <= 0 then return nil end
    return math.floor(book.total_seconds * (1 - fraction) / fraction)
end

--- 今天在这本书上的阅读时长；日桶按日期升序，末格即今天。
---@param book table Current.book(true) 快照
---@return number
function M.todaySeconds(book)
    return book.buckets[#book.buckets].seconds
end

--- 没有在读书籍时的居中空态卡。
---@param rect table 全屏矩形
---@return table[]
function M.empty(rect)
    return U.emptyBlocks(Layout.panel({
        wide = true, height = math.floor(rect.h * 0.3), screen_w = rect.w, screen_h = rect.h,
    }), _("当前阅读"), _("当前没有正在阅读的书籍"))
end

--- 卡片底：不透明白卡带轻阴影，或叠在背景上的半透明白。
local function panel(blocks, x, y, w, h, style)
    blocks[#blocks + 1] = {
        kind = "panel", x = x, y = y, width = w, height = h, radius = style.radius,
        color = Blitbuffer.COLOR_WHITE,
        shadow = style.lighten == nil and 2 or nil,
        lighten = style.lighten,
    }
end

--- 单行文字块；超宽按省略号截断。
local function line(blocks, text, x, y, w, size, opts)
    local fitted, fitted_size = Title.fitSingleLine(text, w, size, size, Render.measureText)
    blocks[#blocks + 1] = {
        text = fitted, x = x, y = y, width = w, size = fitted_size,
        bold = opts.bold, color = opts.color, align = opts.align, box = false,
    }
end

--- 书卡：可选左侧封面缩略图，右侧书名 / 作者 / 章节。
---@return number 卡片高度
local function bookCard(blocks, book, x, y, w, style)
    local pad = style.pad
    local cover_w = style.thumb and math.floor(w * 0.18) or 0
    local cover_h = math.floor(cover_w * 1.5)
    local text_x = x + pad + (cover_w > 0 and cover_w + pad or 0)
    local text_w = x + w - pad - text_x
    local title_text, title_size = Title.fitSingleLine(book.title, text_w, style.title_size, 16,
        Render.measureText)
    local title_h = lineHeight(title_size, true)
    local metas = { U.chapterLine(book) }
    if book.authors ~= "" then table.insert(metas, 1, book.authors) end
    local meta_h = lineHeight(15)
    local gap = math.floor(pad / 2)
    local text_h = title_h + #metas * (gap + meta_h)
    local h = math.max(cover_h, text_h) + pad * 2
    panel(blocks, x, y, w, h, style)
    if cover_w > 0 then
        blocks[#blocks + 1] = {
            kind = "widget",
            widget = select(1, BookInfo.cover(nil, nil, book, cover_w, cover_h, { shadow = false })),
            x = x + pad, y = y + pad, width = cover_w, height = cover_h,
        }
    end
    local ty = y + math.floor((h - text_h) / 2)
    blocks[#blocks + 1] = {
        text = title_text, x = text_x, y = ty, width = text_w, size = title_size,
        bold = true, box = false,
    }
    ty = ty + title_h
    for _, meta in ipairs(metas) do
        ty = ty + gap
        line(blocks, meta, text_x, ty, text_w, 15, { color = U.MUTED })
        ty = ty + meta_h
    end
    return h
end

--- 进度卡：标签 + 页数，下方 BookInfo 同源进度条。
---@return number 卡片高度
local function progressCard(blocks, book, x, y, w, style)
    local pad = style.pad
    local inner_w = w - pad * 2
    local label_h = lineHeight(14)
    local gap = math.floor(pad / 2)
    local bar, bar_h = BookInfo.progressRow(inner_w, book.percent)
    local h = pad * 2 + label_h + gap + bar_h
    local pages = select(2, U.progress(book))
    panel(blocks, x, y, w, h, style)
    local half = math.floor(inner_w / 2)
    line(blocks, _("阅读进度"), x + pad, y + pad, half, 14, { color = U.MUTED })
    line(blocks, pages, x + pad + half, y + pad, inner_w - half, 14, { color = U.MUTED, align = "right" })
    blocks[#blocks + 1] = {
        kind = "widget", widget = bar,
        x = x + pad, y = y + pad + label_h + gap, width = inner_w, height = bar_h,
    }
    return h
end

--- 指标卡：小号标签 + 大号数值。
---@return number 卡片高度
local function metricCard(blocks, label, value, x, y, w, style)
    local pad = style.pad
    local label_h = lineHeight(14)
    local gap = math.floor(pad / 2)
    local h = pad * 2 + label_h + gap + lineHeight(22, true)
    panel(blocks, x, y, w, h, style)
    line(blocks, label, x + pad, y + pad, w - pad * 2, 14, { color = U.MUTED })
    line(blocks, value, x + pad, y + pad + label_h + gap, w - pad * 2, 22, { bold = true })
    return h
end

--- 整屏卡片堆，贴底排布。
---@param rect table 全屏矩形
---@param opts { thumb: boolean, lighten: number|nil, title_size: number }
---@return table[]
function M.stack(rect, opts)
    local book = Current.book(true)
    if not book then return M.empty(rect) end
    ensureUI()
    local margin = math.floor(rect.w * 0.07)
    local gap = math.floor(rect.w * 0.03)
    local style = {
        thumb = opts.thumb, lighten = opts.lighten, title_size = opts.title_size,
        pad = math.max(12, math.floor(rect.w * 0.04)),
        radius = math.max(8, math.floor(rect.w * 0.035)),
    }
    local x, w = rect.x + margin, rect.w - margin * 2
    local blocks = {}
    local y = bookCard(blocks, book, x, 0, w, style) + gap
    y = y + progressCard(blocks, book, x, y, w, style) + gap
    local half = math.floor((w - gap) / 2)
    local remaining = M.remainingSeconds(book)
    metricCard(blocks, _("今日阅读"), U.duration(M.todaySeconds(book)), x, y, half, style)
    y = y + metricCard(blocks, _("预计剩余"), remaining and U.duration(remaining) or _("暂无"),
        x + w - half, y, half, style)
    local dy = rect.y + rect.h - margin - y
    for _, block in ipairs(blocks) do block.y = block.y + dy end
    return blocks
end

return M
