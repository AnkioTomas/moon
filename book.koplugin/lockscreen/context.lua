--[[--
锁屏数据上下文：当前书、账单、书架与高亮。

@module koplugin.book.lockscreen.context
--]]

local BookDB = require("utils.db.book")
local StatsDB = require("utils.db.stats")
local MoonSettings = require("utils.settings")
local Paths = require("utils.paths")
local lfs = require("libs/libkoreader-lfs")

local M = {}

---@param book table
---@param source_id string
---@return table
local function shelfBook(book, source_id)
    local sid = book.source_id or source_id
    local stable_id = book.stable_id
    local cover
    if type(stable_id) == "string" and stable_id ~= "" then
        local path = Paths.coverPath(stable_id, sid)
        if lfs.attributes(path, "mode") == "file" then
            cover = path
        end
    end
    return {
        source_id = sid,
        stable_id = stable_id,
        title = book.title or stable_id or "",
        authors = book.authors or "",
        percent = tonumber(book.percent) or 0,
        cover = cover,
    }
end

---@return table|nil 当前阅读会话
local function currentSession()
    return require("ui.reader.session").current()
end

--- 组装锁屏用的书本快照（会话优先字段 + 库表/统计兜底）。
---@param opts table
---@return table
local function buildBook(opts)
    local source_id = opts.source_id
    local stable_id = opts.stable_id
    local stats = StatsDB.summaryByBook(source_id, stable_id)
    local chapter_count = opts.chapter_count
    if chapter_count == nil and source_id and stable_id then
        local toc = require("book.store").toc({
            source_id = source_id,
            stable_id = stable_id,
        })
        chapter_count = toc and #toc or nil
    end
    return {
        source_id = source_id,
        stable_id = stable_id,
        title = opts.title or stable_id,
        authors = opts.authors or "",
        percent = tonumber(opts.percent) or 0,
        page = tonumber(opts.page) or 0,
        total_pages = tonumber(opts.total_pages) or 0,
        chapter_idx = opts.chapter_idx ~= nil and tonumber(opts.chapter_idx) or nil,
        chapter_count = chapter_count,
        total_seconds = stats.total_seconds,
        pages = stats.pages or 0,
    }
end

---@param ts number|nil Unix 时间戳；省略时使用当前时间
---@return number 当地时区当天零点时间戳
local function dayStart(ts)
    local t = os.date("*t", ts or os.time())
    ---@cast t osdate
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

--- 补齐逐日桶：从 start 到 end（左闭右开）每天一格，无数据为 0。
---@param rows table[]
---@param start_ts number
---@param end_ts number
---@return table[] buckets { key, label, seconds, pages }
local function fillDayBuckets(rows, start_ts, end_ts)
    local by_ymd = {}
    for _, row in ipairs(rows or {}) do
        if type(row.ymd) == "string" then
            by_ymd[row.ymd] = row
        end
    end
    local buckets = {}
    local t = os.date("*t", start_ts)
    ---@cast t osdate
    -- 用正午推进，避开夏令时跳变
    local cursor = os.time({ year = t.year, month = t.month, day = t.day, hour = 12 })
    local guard = 0
    while cursor < end_ts and guard < 400 do
        guard = guard + 1
        local ymd = os.date("%Y-%m-%d", cursor)
        local hit = by_ymd[ymd]
        buckets[#buckets + 1] = {
            key = ymd,
            ymd = ymd, -- 兼容旧字段名
            label = ymd:sub(6), -- MM-DD
            seconds = hit and (tonumber(hit.seconds) or 0) or 0,
            pages = hit and (tonumber(hit.pages) or 0) or 0,
        }
        local n = os.date("*t", cursor)
        ---@cast n osdate
        cursor = os.time({ year = n.year, month = n.month, day = n.day + 1, hour = 12 })
    end
    return buckets
end

--- 给当前书挂上近 7 日阅读桶（阅读统计柱图用）。
---@param book table|nil
---@return table|nil
local function withRecentBuckets(book)
    if not book then
        return nil
    end
    local end_ts = os.time() + 1
    local start_ts = dayStart() - 6 * 86400
    book.buckets = fillDayBuckets(
        StatsDB.dailyByBook(book.source_id, book.stable_id, 7),
        start_ts,
        end_ts
    )
    return book
end

--- 无阅读会话时：按 last_open 取最近一本（优先未读完）。
---@return table|nil
local function latestReadingBook()
    local recent = BookDB.recent(16)
    if #recent == 0 then
        return nil
    end
    local row
    for _, book in ipairs(recent) do
        if (tonumber(book.percent) or 0) < 100 then
            row = book
            break
        end
    end
    row = row or recent[1]
    local progress = require("utils.db.progress").get(row.source_id, row.stable_id)
    -- 全书进度以 books.percent 为准；pending_progress 只补章节下标
    local chapter_idx = (progress and progress.chapter_idx) or row.last_chapter_idx
    return withRecentBuckets(buildBook({
        source_id = row.source_id,
        stable_id = row.stable_id,
        title = row.title,
        authors = row.authors,
        percent = tonumber(row.percent) or 0,
        chapter_idx = chapter_idx,
    }))
end

---@return table|nil 最近正在阅读的书及统计；无最近打开记录时返回 nil
function M.currentBook()
    local cur = currentSession()
    local identity = cur and cur.identity
    if identity and cur then
        local book = identity.book or BookDB.get(identity.source_id, identity.stable_id) or {}
        local toc = require("ui.reader.session").toc()
        return withRecentBuckets(buildBook({
            source_id = identity.source_id,
            stable_id = identity.stable_id,
            title = book.title or identity.stable_id,
            authors = book.authors,
            percent = tonumber(cur.percent) or tonumber(book.percent) or 0,
            page = tonumber(cur.page) or 0,
            total_pages = tonumber(cur.total_pages) or 0,
            chapter_idx = identity.chapter_idx,
            chapter_count = toc and #toc or nil,
        }))
    end
    -- 锁屏多在无 Reader 会话时生成（熄屏/桌面刷新）：回退到 last_open 最近一本
    return latestReadingBook()
end

---@param period string|nil today/7d/30d/month；未知值按 7d 处理
---@return number start_ts, number end_ts 账单查询时间范围
function M.billRange(period)
    local now = os.time()
    local finish = now + 1
    if period == "today" then
        return dayStart(now), finish
    elseif period == "30d" then
        return dayStart(now) - 29 * 86400, finish
    elseif period == "month" then
        local t = os.date("*t", now)
        ---@cast t osdate
        t.day, t.hour, t.min, t.sec = 1, 0, 0, 0
        return os.time(t), finish
    end
    return dayStart(now) - 6 * 86400, finish
end

--- 补齐逐小时桶：本地时区 0–23，无数据为 0。
---@param rows table[]
---@return table[] buckets { key, label, seconds, pages }
local function fillHourBuckets(rows)
    local by_hour = {}
    for _, row in ipairs(rows or {}) do
        local h = tonumber(row.hour)
        if h then
            by_hour[h] = row
        end
    end
    local buckets = {}
    for h = 0, 23 do
        local hit = by_hour[h]
        local key = string.format("%02d", h)
        buckets[#buckets + 1] = {
            key = key,
            label = key,
            seconds = hit and (tonumber(hit.seconds) or 0) or 0,
            pages = hit and (tonumber(hit.pages) or 0) or 0,
        }
    end
    return buckets
end

---@return table {period, start_ts, end_ts, summary, books, grain, buckets}
function M.bill()
    local c = MoonSettings.get()
    local period = c.lock_screen_bill_period or "7d"
    local start_ts, end_ts = M.billRange(period)
    local source_id = c.active_source or "local"
    local grain = period == "today" and "hour" or "day"
    local buckets
    if grain == "hour" then
        buckets = fillHourBuckets(StatsDB.periodHours(source_id, start_ts, end_ts))
    else
        buckets = fillDayBuckets(StatsDB.periodDays(source_id, start_ts, end_ts), start_ts, end_ts)
    end
    return {
        period = period,
        start_ts = start_ts,
        end_ts = end_ts,
        summary = StatsDB.periodSummary(source_id, start_ts, end_ts),
        books = StatsDB.periodBooks(source_id, start_ts, end_ts, 5),
        grain = grain,
        buckets = buckets,
        -- 兼容旧字段：按天粒度时等于 buckets
        days = grain == "day" and buckets or nil,
    }
end

--- 物理书架数据：正在阅读（书脊）+ 其余封面书。只读本地封面缓存，不触网。
---@return { reading: table[], covers: table[] }
function M.bookshelf()
    local source_id = MoonSettings.get().active_source or "local"
    local recent = BookDB.recentBySource(source_id, 64)
    local reading, covers, seen = {}, {}, {}

    for _, row in ipairs(recent) do
        if (tonumber(row.percent) or 0) < 100 and #reading < 12 then
            reading[#reading + 1] = shelfBook(row, source_id)
            seen[row.stable_id] = true
        end
    end
    if #reading == 0 then
        for i = 1, math.min(8, #recent) do
            local row = recent[i]
            reading[#reading + 1] = shelfBook(row, source_id)
            seen[row.stable_id] = true
        end
    end
    for _, row in ipairs(recent) do
        if not seen[row.stable_id] and #covers < 36 then
            covers[#covers + 1] = shelfBook(row, source_id)
            seen[row.stable_id] = true
        end
    end
    if #covers < 24 then
        local rows = select(1, BookDB.listBySource(source_id, { limit = 48, offset = 0 }))
        for _, row in ipairs(rows) do
            if not seen[row.stable_id] and #covers < 36 then
                covers[#covers + 1] = shelfBook(row, source_id)
                seen[row.stable_id] = true
            end
        end
    end
    return { reading = reading, covers = covers }
end

---@return string|nil 下一条高亮文本；没有可用高亮时返回 nil
function M.highlight()
    local cur = currentSession()
    local annotations = cur and cur.ui.annotation and cur.ui.annotation.annotations
    if type(annotations) ~= "table" then
        return nil
    end
    local texts = {}
    for _, item in ipairs(annotations) do
        -- KOReader annotations do not carry a type field: drawer marks highlights/notes.
        if item.drawer and type(item.text) == "string" and item.text ~= "" then
            texts[#texts + 1] = item.text
        end
    end
    if #texts == 0 then
        return nil
    end
    local c = MoonSettings.get()
    local idx = (tonumber(c.lock_screen_quote_index) or 0) % #texts + 1
    c.lock_screen_quote_index = idx
    MoonSettings.save()
    return texts[idx]
end

return M
