--[[--
主体：当前阅读（封面 / 书籍信息 / 进度）。

布局直接复用桌面 BookInfo.hero，锁屏只负责放进面板矩形并离屏绘制。

@module koplugin.book.lockscreen.components.current
--]]

local BookDB = require("utils.db.book")
local StatsDB = require("utils.db.stats")
local ProgressDB = require("utils.db.progress")
local Session = require("ui.reader.session")
local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")
local U = require("lockscreen.components.util")
local _ = require("gettext")

local M = {
    id = "current",
    label = _("当前阅读"),
    live = true,
    preferred_height = 0.30,
    min_height = 150,
}

local BookInfo

--- 延迟加载桌面同源组件，避免锁屏初始化依赖完整 UI 树。
local function ensureUI()
    if BookInfo then return end
    BookInfo = require("ui.components.bookinfo")
end

local function coverPath(stable_id, source_id)
    if type(stable_id) ~= "string" or stable_id == "" then return nil end
    local path = Paths.coverPath(stable_id, source_id)
    return lfs.attributes(path, "mode") == "file" and path or nil
end

--- 组装锁屏用的当前书快照；会话关闭后回退到当前源最近打开的书。
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
        cover = coverPath(stable_id, source_id),
    }
end

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

local function latestBook()
    local source_id = MoonSettings.get().active_source or "local"
    local recent = BookDB.recentBySource(source_id, 16)
    if #recent == 0 then return nil end
    local row
    for _, book in ipairs(recent) do
        if (tonumber(book.percent) or 0) < 100 then
            row = book
            break
        end
    end
    row = row or recent[1]
    local progress = ProgressDB.get(source_id, row.stable_id) or {}
    return buildBook{
        source_id = source_id,
        stable_id = row.stable_id,
        title = row.title,
        authors = row.authors,
        percent = progress.fraction ~= nil and progress.fraction * 100
            or tonumber(row.percent) or 0,
        chapter_idx = progress.chapter_idx or row.last_chapter_idx,
        chapter_title = progress.chapter_title,
        page = progress.page,
        total_pages = progress.total_pages,
    }
end

--- 返回当前书快照；统计组件通过同一入口追加累计时长和日桶。
---@param with_stats boolean|nil
---@return table|nil
function M.book(with_stats)
    local cur = Session.current()
    local identity = cur and cur.identity
    local book
    if identity and cur then
        local db_book = identity.book or BookDB.get(identity.source_id, identity.stable_id) or {}
        local progress = ProgressDB.get(identity.source_id, identity.stable_id) or {}
        book = buildBook{
            source_id = identity.source_id,
            stable_id = identity.stable_id,
            title = db_book.title or identity.stable_id,
            authors = db_book.authors,
            percent = tonumber(cur.percent) or tonumber(db_book.percent) or 0,
            page = tonumber(cur.page) or progress.page,
            total_pages = tonumber(cur.total_pages) or progress.total_pages,
            chapter_idx = identity.chapter_idx,
            chapter_title = progress.chapter_title or db_book.chapter_title,
        }
    else
        book = latestBook()
    end
    return with_stats and withStats(book) or book
end

--- 当前阅读主体：白卡 + BookInfo.hero（封面 / 书名 / 作者 / 章节 / 进度）。
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
    local hero, hero_h = BookInfo.hero(nil, nil, book, {
        width = rect.w,
        pad = rect.pad,
        subtitle = subtitle,
        show_progress = true,
    })
    local y = rect.y + math.max(0, math.floor((rect.h - hero_h) / 2))
    return {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = require("ffi/blitbuffer").COLOR_WHITE,
        },
        {
            kind = "widget", role = "hero",
            widget = hero, x = rect.x, y = y, width = rect.w, height = hero_h,
        },
    }
end

return M
