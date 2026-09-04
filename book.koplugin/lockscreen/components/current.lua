--[[--
主体：当前阅读（封面 / 书籍信息 / 进度）。

布局直接复用桌面 BookInfo.hero，锁屏只负责放进面板矩形并离屏绘制。

@module koplugin.book.lockscreen.components.current
--]]

local Catalog = require("book.catalog")
local StatsDB = require("db.stats")
local Library = require("lockscreen.components.library")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "current",
    label = _("当前阅读"),
    -- 面板高度以 hero 内容为准；这里只给布局层一个偏紧的上限，避免白卡上下留白。
    preferred_height = 0.20,
    min_height = 120,
}

local BookInfo

--- 延迟加载桌面同源组件，避免锁屏初始化依赖完整 UI 树。
local function ensureUI()
    if BookInfo then return end
    BookInfo = require("ui.components.bookinfo")
end

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
---@return table|nil 书库为空时 nil
local function currentBook()
    local source_id = Library.activeSourceId()
    local recent = Catalog.recentBooks(source_id, 16)
    if #recent == 0 then return nil end
    local row
    for _, book in ipairs(recent) do
        if (tonumber(book.percent) or 0) < 100 then
            row = book
            break
        end
    end
    row = row or recent[1]
    return buildBook{
        source_id = source_id,
        stable_id = row.stable_id,
        title = row.title,
        authors = row.authors,
        percent = row.percent,
        chapter_idx = row.chapter_idx,
        chapter_title = row.chapter_title,
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

--- 当前阅读主体：白卡贴合 BookInfo.hero 高度（封面 / 书名 / 作者 / 章节 / 进度）。
---@param rect table
---@return table[]
function M.blocks(rect)
    local book = M.book()
    if not book then
        return U.emptyBlocks(rect, _("当前阅读"), _("当前没有正在阅读的书籍"))
    end
    ensureUI()
    local chapter = U.chapterLine(book)
    local subtitle = chapter ~= "" and (_("章节") .. " · " .. chapter) or nil
    -- 左右边距取锁屏面板 pad，但封顶 20，避免宽屏把卡片撑得过松。
    local pad = math.max(16, math.min(rect.pad or 16, 20))
    local hero, hero_h = BookInfo.hero(nil, nil, book, {
        width = rect.w,
        pad = pad,
        subtitle = subtitle,
        show_progress = true,
        sync = true,
    })
    -- hero 自身上下只有 UI.sz(6)；外面再留一圈，白卡不至于贴边。
    local inset_v = math.max(10, math.floor(pad * 0.6))
    local card_h = hero_h + inset_v * 2
    local y = rect.y + math.max(0, math.floor((rect.h - card_h) / 2))
    return {
        {
            kind = "panel", x = rect.x, y = y, width = rect.w, height = card_h,
            radius = rect.radius, shadow = 2, color = require("ffi/blitbuffer").COLOR_WHITE,
        },
        {
            kind = "widget",
            widget = hero, x = rect.x, y = y + inset_v, width = rect.w, height = hero_h,
        },
    }
end

return M
