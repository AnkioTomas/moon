--[[--
reading_stats 表：自采集与拉取的阅读统计（逐页事件与云端聚合记录，按记录身份去重）。

sync_status=0 表示待上传，1 表示已与远端同步。

身份即 BookIdentity(source_id + stable_id)，天然按源隔离。

@module koplugin.book.db.stats
--]]

local Base = require("db.base")
local logger = require("logger")

local StatsDB = {}

local DAY_RECORD = "day"
local BOOK_RECORD = "book"

--- 创建阅读统计表及聚合查询索引。
--- 仅在 Base.open() 的一次性 schema 初始化阶段调用。
---@return boolean 成功返回 true，SQL 失败返回 false
function StatsDB.ensureSchema()
    if not Base.exec([[
CREATE TABLE IF NOT EXISTS reading_stats (
  id INTEGER PRIMARY KEY AUTOINCREMENT, source_id TEXT NOT NULL,
  stable_id TEXT NOT NULL, record_type TEXT NOT NULL,
  page INTEGER NOT NULL DEFAULT 0,
  start_time INTEGER NOT NULL, duration INTEGER NOT NULL DEFAULT 0,
  total_pages INTEGER NOT NULL DEFAULT 0, chapter_idx INTEGER,
  chapter_fraction REAL, sync_status INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_reading_stats_time ON reading_stats(source_id, start_time);
]]) then return false end

    if not Base.exec([[CREATE UNIQUE INDEX IF NOT EXISTS idx_reading_stats_identity
        ON reading_stats(source_id, stable_id, page, start_time, duration);]]) then
        return false
    end
    return true
end

--- 云端 pull 覆盖前的清理：**只删本次回包时间窗口内的合成行**。
---
--- 两条边界都是数据事故的教训，不能放宽：
--- 1. 只删合成行（`__*:day:*` / `__*:book:*`）。本地逐页记录推送成功后也是
---    `sync_status=1`，按 sync_status 删会把用户自己设备采集的阅读历史一起删掉。
--- 2. 只删窗口内。回包通常只覆盖近一个月，删整源等于每同步一次就抹掉更早的历史。
---@param source_id string
---@param from_ts number 窗口起（含）
---@param to_ts number 窗口止（含）
---@param prefix string|nil 限定 stable_id 前缀；缺省则窗口内全部合成行
---@return boolean
function StatsDB.deleteSyntheticInRange(source_id, from_ts, to_ts, prefix)
    from_ts = tonumber(from_ts)
    to_ts = tonumber(to_ts)
    if not from_ts or not to_ts then
        return false
    end
    if prefix ~= nil then
        return Base.exec(
            [[DELETE FROM reading_stats
              WHERE source_id=? AND record_type IN ('day','book')
                AND start_time>=? AND start_time<=? AND stable_id LIKE ?;]],
            source_id, from_ts, to_ts, prefix .. "%"
        ) ~= nil
    end
    return Base.exec(
        [[DELETE FROM reading_stats
          WHERE source_id=? AND record_type IN ('day','book')
            AND start_time>=? AND start_time<=?;]],
        source_id, from_ts, to_ts
    ) ~= nil
end

--- 云端日桶/书桶是合成行：按书、按小时统计里必须排掉，否则同一天既算云端整天
--- 时长又算本地逐页时长，账单直接翻倍。
local NOT_SYNTHETIC = " AND record_type='page' "

--- 按天合并云端日桶与本地页记录：有云端日桶的日期以云端为准。
---@param source_id string
---@param start_ts number|nil 可选时间范围（含）
---@param end_ts number|nil 可选时间范围（不含）
---@return table[] rows { ymd, seconds, pages }
local function mergedDailyRows(source_id, start_ts, end_ts)
    local range = ""
    local args = { source_id }
    if start_ts and end_ts then
        range = " AND start_time>=? AND start_time<?"
        args[2] = tonumber(start_ts) or 0
        args[3] = tonumber(end_ts) or 0
    end
    local result, nrows = Base.query(
        [[SELECT date(start_time,'unixepoch','localtime') AS day,
                 stable_id, record_type, COALESCE(SUM(duration),0), COUNT(*)
          FROM reading_stats WHERE source_id=]] .. "?" .. range .. [[
          GROUP BY day, stable_id, record_type ORDER BY day;]],
        unpack(args, 1, #args)
    )
    local cloud, local_days, pages = {}, {}, {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            local day = result[1][i]
            local record_type = result[3][i]
            local seconds = tonumber(result[4][i]) or 0
            local count = tonumber(result[5][i]) or 0
            if record_type == BOOK_RECORD then
                -- 周期书单排行，不参与日历总时长
            elseif record_type == DAY_RECORD then
                cloud[day] = seconds
                pages[day] = (pages[day] or 0) + count
            else
                local_days[day] = (local_days[day] or 0) + seconds
                pages[day] = (pages[day] or 0) + count
            end
        end
    end
    local seen, rows = {}, {}
    for day, seconds in pairs(cloud) do
        seen[day] = true
        rows[#rows + 1] = { ymd = day, seconds = seconds, pages = pages[day] or 0 }
    end
    for day, seconds in pairs(local_days) do
        if not seen[day] then
            rows[#rows + 1] = { ymd = day, seconds = seconds, pages = pages[day] or 0 }
        end
    end
    table.sort(rows, function(a, b) return a.ymd < b.ymd end)
    return rows
end

--- 追加一条阅读统计。
---@param row { source_id: string, stable_id: string, page: number, start_time: number, duration: number, total_pages: number }
---@param synced boolean|nil
---@return boolean
function StatsDB.add(row, synced)
    local source_id = row.source_id
    local start_time = tonumber(row.start_time)
    local duration = tonumber(row.duration)
    if not start_time or not duration or duration <= 0 then
        return false
    end
    return Base.exec(
        [[INSERT INTO reading_stats (
            source_id, stable_id, record_type, page, start_time, duration, total_pages,
            chapter_idx, chapter_fraction, sync_status
          ) VALUES (?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(source_id, stable_id, page, start_time, duration)
          DO UPDATE SET sync_status=MAX(reading_stats.sync_status, excluded.sync_status);]],
        source_id,
        row.stable_id,
        row.record_type,
        tonumber(row.page) or 0,
        start_time,
        duration,
        tonumber(row.total_pages) or 0,
        tonumber(row.chapter_idx),
        tonumber(row.chapter_fraction),
        synced and 1 or 0
    ) ~= nil
end

--- 列出指定源的待上传统计。
---@param source_id string
---@return table[]
function StatsDB.unsyncedBySource(source_id)
    local result, nrows = Base.query(
        [[SELECT id, stable_id, page, start_time, duration, total_pages,
                 chapter_idx, chapter_fraction, sync_status
          FROM reading_stats WHERE source_id=? AND sync_status=0 ORDER BY start_time ASC;]],
        source_id
    )
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                id = tonumber(result[1][i]) or 0,
                stable_id = result[2][i],
                page = tonumber(result[3][i]) or 0,
                start_time = tonumber(result[4][i]) or 0,
                duration = tonumber(result[5][i]) or 0,
                total_pages = tonumber(result[6][i]) or 0,
                chapter_idx = tonumber(result[7][i]),
                chapter_fraction = tonumber(result[8][i]),
                sync_status = tonumber(result[9][i]) or 0,
            }
        end
    end
    return rows
end

--- 记录是否已存在（命中记录身份唯一索引）。
---@param row table
---@return boolean
function StatsDB.exists(row)
    local source_id = row.source_id
    return Base.rowexec(
        [[SELECT 1 FROM reading_stats
          WHERE source_id=? AND stable_id=? AND page=? AND start_time=?
            AND duration=? LIMIT 1;]],
        source_id,
        row.stable_id,
        tonumber(row.page) or 0,
        tonumber(row.start_time) or 0,
        tonumber(row.duration) or 0
    ) ~= nil
end

--- 云端拉取入库：按 replace 策略清理旧已同步行后写入本批记录，全程单事务。
--- 中途失败整体回滚，不会出现「删掉了旧数据但没写进新数据」的空窗。
---@param source_id string
---@param replace BookStatsPullReplace|nil
---@param rows table[]|nil
---@return { imported: integer, skipped: integer }|nil
function StatsDB.replaceSynced(source_id, replace, rows)
    rows = rows or {}
    -- 清理范围由本批数据自己界定：回包没覆盖到的时间段一律不动。
    -- rows 为空（协议异常/网络截断）时 from 为 nil，什么都不删——与
    -- book.note 的 saveRemoteBuckets 同一立场：宁可漏掉云端删除。
    local from, to
    for _, row in ipairs(rows) do
        local ts = tonumber(row.start_time)
        if ts then
            from = (from == nil or ts < from) and ts or from
            to = (to == nil or ts > to) and ts or to
        end
    end
    --- 按 replace 策略清掉本批覆盖时间段内的旧已同步行。
    ---@return boolean
    local function clearRange()
        if not (replace and from and to) then return true end
        if replace.mode == "prefix" and replace.stable_prefixes then
            for _, prefix in ipairs(replace.stable_prefixes) do
                if not StatsDB.deleteSyntheticInRange(source_id, from, to, prefix) then return false end
            end
            return true
        end
        return StatsDB.deleteSyntheticInRange(source_id, from, to)
    end

    if not Base.exec("BEGIN IMMEDIATE;") then
        return nil
    end
    local result = { imported = 0, skipped = 0 }
    local ok = clearRange()
    for _, row in ipairs(rows) do
        if not ok then break end
        local duplicate = StatsDB.exists(row)
        ok = StatsDB.add(row, true)
        if duplicate then
            result.skipped = result.skipped + 1
        else
            result.imported = result.imported + 1
        end
    end
    if ok and Base.exec("COMMIT;") then return result end
    Base.exec("ROLLBACK;")
    logger.warn("book.db replaceSynced failed", source_id)
    return nil
end

--- 汇总某源阅读统计：总时长/页数、近 7 天时长、最长单日。
---@param source_id string
---@return { total_seconds: number, total_pages: number, last7_seconds: number, longest_day_seconds: number }
function StatsDB.summaryBySource(source_id)
    local daily = mergedDailyRows(source_id)
    local total_seconds, total_pages, last7_seconds, longest_day_seconds = 0, 0, 0, 0
    local cutoff = os.date("%Y-%m-%d", os.time() - 6 * 86400)
    for _, row in ipairs(daily) do
        local seconds = tonumber(row.seconds) or 0
        total_seconds = total_seconds + seconds
        total_pages = total_pages + (tonumber(row.pages) or 0)
        if row.ymd >= cutoff then
            last7_seconds = last7_seconds + seconds
        end
        if seconds > longest_day_seconds then
            longest_day_seconds = seconds
        end
    end
    return {
        total_seconds = total_seconds,
        total_pages = total_pages,
        last7_seconds = last7_seconds,
        longest_day_seconds = longest_day_seconds,
    }
end

--- 汇总单本书阅读统计：总时长/已读页数/上次阅读时间（详情页用）。
--- 已上传和远端拉取记录仍保留，详情聚合始终读取完整本地历史。
---@param source_id string
---@param stable_id string
---@return { total_seconds: number, pages: number, last_read: number }
function StatsDB.summaryByBook(source_id, stable_id)
    local total_seconds, pages, last_read = Base.rowexec(
        [[SELECT COALESCE(SUM(duration),0), COUNT(*), COALESCE(MAX(start_time),0)
          FROM reading_stats WHERE source_id=? AND stable_id=?;]],
        source_id,
        stable_id
    )
    return {
        total_seconds = tonumber(total_seconds) or 0,
        pages = tonumber(pages) or 0,
        last_read = tonumber(last_read) or 0,
    }
end

--- 单本书按天聚合（详情页「最近几天」卡片用，最近在前）。
--- 已上传和远端拉取记录仍保留，详情聚合始终读取完整本地历史。
---@param source_id string
---@param stable_id string
---@param limit number|nil 最多返回天数，默认 5
---@return table[] rows { ymd, seconds, pages }（日期倒序）
function StatsDB.dailyByBook(source_id, stable_id, limit)
    local result, nrows = Base.query(
        [[SELECT date(start_time,'unixepoch','localtime') AS day,
                 SUM(duration), COUNT(*)
          FROM reading_stats WHERE source_id=? AND stable_id=?
          GROUP BY day ORDER BY day DESC LIMIT ?;]],
        source_id,
        stable_id,
        tonumber(limit) or 5
    )
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                ymd = result[1][i],
                seconds = tonumber(result[2][i]) or 0,
                pages = tonumber(result[3][i]) or 0,
            }
        end
    end
    return rows
end

--- 按天聚合某源阅读统计（本地洞察日历用）。
---@param source_id string
---@return table[] rows { ymd, seconds, pages }（按日期升序）
function StatsDB.dailyBySource(source_id)
    return mergedDailyRows(source_id)
end

--- 按天按书聚合某源阅读统计（本地洞察当日书单用）。
--- 进度近似 = 当日读到最深页 / 当时总页数。
---@param source_id string
---@return table[] rows { ymd, stable_id, seconds, max_page, max_total_pages }（日期升序、时长降序）
function StatsDB.dailyBooksBySource(source_id)
    local result, nrows = Base.query(
        [[SELECT date(start_time,'unixepoch','localtime') AS day,
                 stable_id, SUM(duration), MAX(page), MAX(total_pages)
          FROM reading_stats WHERE source_id=?
            AND record_type='page'
          GROUP BY day, stable_id ORDER BY day, 3 DESC;]],
        source_id
    )
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                ymd = result[1][i],
                stable_id = result[2][i],
                seconds = tonumber(result[3][i]) or 0,
                max_page = tonumber(result[4][i]) or 0,
                max_total_pages = tonumber(result[5][i]) or 0,
            }
        end
    end
    return rows
end

--- 指定时间范围内某源的账单汇总。
---@param source_id string
---@param start_ts number
---@param end_ts number
---@return { total_seconds: number, book_count: number, pages: number }
function StatsDB.periodSummary(source_id, start_ts, end_ts)
    -- 书数/页数只看真实书的记录；总时长按天走「云端日桶优先」的合并口径，
    -- 与洞察日历保持一致，也避免同一天双重计数。
    local _, books, pages = Base.rowexec(
        [[SELECT 0, COUNT(DISTINCT stable_id), COUNT(*)
          FROM reading_stats WHERE source_id=? AND start_time>=? AND start_time<?]]
        .. NOT_SYNTHETIC .. ";",
        source_id, tonumber(start_ts) or 0, tonumber(end_ts) or 0
    )
    local total = 0
    for _i, row in ipairs(mergedDailyRows(source_id, start_ts, end_ts)) do
        total = total + row.seconds
    end
    return {
        total_seconds = total,
        book_count = tonumber(books) or 0,
        pages = tonumber(pages) or 0,
    }
end

--- 指定时间范围内某源阅读时长最多的书。
---@param source_id string
---@param start_ts number
---@param end_ts number
---@param limit number|nil
---@return table[] rows { stable_id, title, authors, percent, seconds, pages }
function StatsDB.periodBooks(source_id, start_ts, end_ts, limit)
    local result, nrows = Base.query(
        [[SELECT r.stable_id, b.title, b.authors, b.percent,
                 SUM(r.duration), COUNT(*)
          FROM reading_stats r LEFT JOIN books b
            ON b.source_id=r.source_id AND b.stable_id=r.stable_id
          WHERE r.source_id=? AND r.start_time>=? AND r.start_time<?
            AND r.record_type='page'
          GROUP BY r.stable_id ORDER BY 5 DESC LIMIT ?;]],
        source_id, tonumber(start_ts) or 0, tonumber(end_ts) or 0,
        math.max(1, tonumber(limit) or 5)
    )
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                stable_id = result[1][i],
                title = result[2][i],
                authors = result[3][i],
                percent = tonumber(result[4][i]) or 0,
                seconds = tonumber(result[5][i]) or 0,
                pages = tonumber(result[6][i]) or 0,
            }
        end
    end
    return rows
end

--- 指定时间范围内某源的逐日统计。
---@param source_id string
---@param start_ts number
---@param end_ts number
---@return table[] rows { ymd, seconds, pages }
function StatsDB.periodDays(source_id, start_ts, end_ts)
    -- 与洞察日历同一口径：有云端日桶的日期以云端为准，不与本地逐页记录相加
    return mergedDailyRows(source_id, start_ts, end_ts)
end

--- 指定时间范围内某源的逐小时统计（本地时区 0–23）。
---@param source_id string
---@param start_ts number
---@param end_ts number
---@return table[] rows { hour, seconds, pages }（hour 为 0–23）
function StatsDB.periodHours(source_id, start_ts, end_ts)
    local result, nrows = Base.query(
        [[SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER),
                 SUM(duration), COUNT(*)
          FROM reading_stats WHERE source_id=? AND start_time>=? AND start_time<?]]
        .. NOT_SYNTHETIC .. [[
          GROUP BY 1 ORDER BY 1;]],
        source_id, tonumber(start_ts) or 0, tonumber(end_ts) or 0
    )
    local rows = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            rows[#rows + 1] = {
                hour = tonumber(result[1][i]) or 0,
                seconds = tonumber(result[2][i]) or 0,
                pages = tonumber(result[3][i]) or 0,
            }
        end
    end
    return rows
end

--- 标记已被 Source 确认的记录。
---@param ids number[]
---@return boolean
function StatsDB.markSynced(ids)
    if #ids == 0 then
        return false
    end
    if not Base.exec("BEGIN IMMEDIATE;") then
        return false
    end
    for _, id in ipairs(ids) do
        if not Base.exec([[UPDATE reading_stats SET sync_status=1 WHERE id=?;]], id) then
            Base.exec("ROLLBACK;")
            return false
        end
    end
    if not Base.exec("COMMIT;") then
        Base.exec("ROLLBACK;")
        return false
    end
    return true
end

return StatsDB
