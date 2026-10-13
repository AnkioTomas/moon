--[[--
主体：当前阅读（封面 / 书籍信息 / 进度）。

白卡里放封面、书名和进度，绘制只用锁屏自己的块。

@module koplugin.book.features.lockscreen.components.current
--]]

local Catalog = require("book.catalog")
local StatsDB = require("book.stats_db")
local Library = require("features.lockscreen.components.library")
local U = require("features.lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "current",
    label = _("当前阅读"),
    -- 面板高度以书卡内容为准；这里只给布局层一个偏紧的上限，避免白卡上下留白。
    preferred_height = 0.20,
    min_height = 120,
}

--- 把零散字段归一成锁屏用的书快照；封面取本地缓存，缺失为 nil。
---@param opts table
---@return table
local function buildBook(opts)
    local source_id, stable_id = opts.source_id, opts.stable_id
    return {
        source_id = source_id,
        stable_id = stable_id,
        title = opts.title or stable_id,
        authors = opts.authors or "",
        percent = tonumber(opts.percent) or 0,
        page = tonumber(opts.page) or 0,
        total_pages = tonumber(opts.total_pages) or 0,
        chapter_idx = tonumber(opts.chapter_idx),
        chapter_title = opts.chapter_title,
        chapter_count = tonumber(opts.chapter_count),
        cover = Library.coverPath(stable_id, source_id),
    }
end

--- 就地补上这本书的累计阅读时长与近 7 天日桶。
---@param book table|nil
---@return table|nil 原表（book 为 nil 时透传 nil）
local function withStats(book)
    if not book then return nil end
    local summary = StatsDB.summaryByBook(book.source_id, book.stable_id)
    book.total_seconds = summary.total_seconds or 0
    local end_ts = U.dayStart() + 86400
    book.buckets = U.dayBuckets(
        StatsDB.dailyByBook(book.source_id, book.stable_id, 7),
        U.dayStart() - 6 * 86400,
        end_ts
    )
    return book
end

--- 当前源最近打开的书，优先取未读完的那本。
--- 元数据来自 books，阅读位置来自 pending_progress。
--- 混合模式下 scope 是源 id 列表，书的源必须取行内 source_id。
---@return table|nil 书库为空时 nil
local function currentBook()
    local recent = Catalog.recentBooks(Library.activeSourceId(), 16)
    if #recent == 0 then return nil end
    local row
    for _idx, book in ipairs(recent) do
        if (tonumber(book.percent) or 0) < 100 then
            row = book
            break
        end
    end
    row = row or recent[1]
    return buildBook{
        source_id = row.source_id,
        stable_id = row.stable_id,
        title = row.title,
        authors = row.authors,
        percent = row.percent,
        chapter_idx = row.chapter_idx,
        chapter_title = row.chapter_title,
        chapter_count = row.chapter_count,
        page = row.page,
        total_pages = row.total_pages,
    }
end

--- 返回当前书快照；统计组件通过同一入口追加累计时长和日桶。
---@param with_stats boolean|nil
---@return table|nil
function M.book(with_stats)
    local book = currentBook()
    return with_stats and withStats(book) or book
end

--- 组合图缓存键：当前书、位置、封面与近 7 日统计任一变化都要重画。
--- 依赖当前书的主体（统计 / 票根 / 卡片）共用这一个键，别各写一份漏字段。
---@return string
function M.cache_key()
    local book = M.book(true)
    if not book then return "none" end
    local parts = {
        book.source_id or "", book.stable_id, book.percent, book.page,
        book.chapter_idx or "", book.cover or "", book.total_seconds,
    }
    for _idx, bucket in ipairs(book.buckets) do
        parts[#parts + 1] = bucket.key .. "," .. bucket.seconds .. "," .. bucket.pages
    end
    return table.concat(parts, ":")
end

--- 指定书的带统计快照（阅读页侧栏票根用：书跟阅读身份走，不取「当前源最近在读」）。
---@param fields table source_id/stable_id/title/authors/percent/page/total_pages/chapter_*
---@return table
function M.snapshot(fields)
    return withStats(buildBook(fields))
end

--- 当前阅读主体：白卡里放封面、书名、作者、章节和进度。
---@param rect table
---@return table[]
function M.blocks(rect)
    local book = M.book()
    if not book then
        return U.emptyBlocks(rect, _("当前阅读"), _("当前没有正在阅读的书籍"))
    end
    local chapter = U.chapterLine(book)
    local pad = math.max(16, math.min(rect.pad or 16, 20))
    local inset_v = math.max(10, math.floor(pad * 0.6))
    local cover_w = math.floor(rect.w * 0.22)
    local cover_h = math.floor(cover_w * 1.45)
    local inner_x = rect.x + pad
    local text_x = inner_x + cover_w + pad
    local text_w = math.max(1, rect.x + rect.w - pad - text_x)
    -- 文字高度实测后才知道卡多高：先在 y=0 排，定下卡片位置再整体下移。
    local head, head_h = U.bookHead(book, _("章节") .. " · " .. chapter, text_x, 0, text_w)
    local bar_gap = 6
    local card_h = math.max(cover_h, head_h + bar_gap + 8) + inset_v * 2
    local y = rect.y + math.max(0, math.floor((rect.h - card_h) / 2))
    local content_y = y + inset_v
    local blocks = {
        {
            kind = "panel", x = rect.x, y = y, width = rect.w, height = card_h,
            radius = rect.radius, shadow = 2, color = require("ffi/blitbuffer").COLOR_WHITE,
        },
        U.coverBlock(book, inner_x, content_y, cover_w, cover_h),
    }
    for _idx, block in ipairs(head) do
        block.y = block.y + content_y
        blocks[#blocks + 1] = block
    end
    -- 进度条右侧留一列给百分比，文字与 6px 细条垂直居中。
    local pct_w = 52
    local bar_y = content_y + head_h + bar_gap
    local bar, bar_h = U.progressBlocks(text_x, bar_y, math.max(1, text_w - pct_w - 8), book.percent)
    for _idx, block in ipairs(bar) do blocks[#blocks + 1] = block end
    blocks[#blocks + 1] = {
        text = U.percentText(book.percent), x = text_x + text_w - pct_w, y = bar_y + math.floor(bar_h / 2) - 9,
        width = pct_w, size = 13, bold = true, align = "right", box = false,
    }
    return blocks
end

return M
