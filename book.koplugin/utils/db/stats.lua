--[[--
reading_stats 表：自采集与拉取的阅读统计（一页一条，按记录身份去重）。

sync_status=0 表示待上传，1 表示已与远端同步。

身份即 BookIdentity(source_id + stable_id)，天然按源隔离。

@module koplugin.book.utils.db.stats
--]]

local Base = require("utils.db.base")
local logger = require("logger")

local StatsDB = {}

--- 远端日桶 stable_id（``__*:day:``）判定。
---@param stable_id string|nil
---@return boolean
local function isRemoteDayStableId(stable_id)
    return type(stable_id) == "string" and stable_id:find(":day:", 1, true) ~= nil
        and stable_id:sub(1, 2) == "__"
end

--- 远端周期书单 stable_id（``__*:book:``）判定；不参与按天总时长。
---@param stable_id string|nil
---@return boolean
local function isRemoteBookStableId(stable_id)
    return type(stable_id) == "string" and stable_id:find(":book:", 1, true) ~= nil
        and stable_id:sub(1, 2) == "__"
end

--- 删除指定源全部已同步统计（云端 pull 覆盖前调用）。
---@param source_id string
---@return boolean
function StatsDB.deleteSyncedBySource(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return false
    end
    Base.ensure()
    return Base.exec([[DELETE FROM reading_stats WHERE source_id=? AND sync_status=1;]], source_id) ~= nil
end

--- 删除指定源、匹配 stable_id 前缀的已同步统计。
---@param source_id string
---@param prefix string
---@return boolean
function StatsDB.deleteSyncedByStablePrefix(source_id, prefix)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(prefix) ~= "string" or prefix == "" then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[DELETE FROM reading_stats WHERE source_id=? AND sync_status=1 AND stable_id LIKE ?;]],
        source_id,
        prefix .. "%"
    ) ~= nil
end

--- 按天合并云端日桶与本地页记录：有云端日桶的日期以云端为准。
---@param source_id string
---@return table[] rows { ymd, seconds, pages }
local function mergedDailyRows(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT date(start_time,'unixepoch','localtime') AS day,
                 stable_id, COALESCE(SUM(duration),0), COUNT(*)
          FROM reading_stats WHERE source_id=?
          GROUP BY day, stable_id ORDER BY day;]],
        source_id
    )
    local cloud, local_days, pages = {}, {}, {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            local day = result[1][i]
            local stable_id = result[2][i]
            local seconds = tonumber(result[3][i]) or 0
            local count = tonumber(result[4][i]) or 0
            if isRemoteBookStableId(stable_id) then
                -- 周期书单排行，不参与日历总时长
            elseif isRemoteDayStableId(stable_id) then
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
    if type(row) ~= "table" then
        return false
    end
    local source_id = Base.requireSourceId(row.source_id)
    if not source_id or type(row.stable_id) ~= "string" or row.stable_id == "" then
        return false
    end
    local start_time = tonumber(row.start_time)
    local duration = tonumber(row.duration)
    if not start_time or not duration or duration <= 0 then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[INSERT INTO reading_stats (
            source_id, stable_id, page, start_time, duration, total_pages,
            chapter_idx, chapter_fraction, sync_status
          ) VALUES (?,?,?,?,?,?,?,?,?)
          ON CONFLICT(source_id, stable_id, page, start_time, duration, total_pages)
          DO UPDATE SET sync_status=MAX(reading_stats.sync_status, excluded.sync_status);]],
        source_id,
        row.stable_id,
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
    source_id = Base.requireSourceId(source_id)
    if not source_id then return {} end
    Base.ensure()
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
    if type(row) ~= "table" then
        return false
    end
    local source_id = Base.requireSourceId(row.source_id)
    if not source_id or type(row.stable_id) ~= "string" or row.stable_id == "" then
        return false
    end
    Base.ensure()
    return Base.rowexec(
        [[SELECT 1 FROM reading_stats
          WHERE source_id=? AND stable_id=? AND page=? AND start_time=?
            AND duration=? AND total_pages=? LIMIT 1;]],
        source_id,
        row.stable_id,
        tonumber(row.page) or 0,
        tonumber(row.start_time) or 0,
        tonumber(row.duration) or 0,
        tonumber(row.total_pages) or 0
    ) ~= nil
end

--- 云端拉取入库：按 replace 策略清理旧已同步行后写入本批记录，全程单事务。
--- 中途失败整体回滚，不会出现「删掉了旧数据但没写进新数据」的空窗。
---@param source_id string
---@param replace BookStatsPullReplace|nil
---@param rows table[]|nil
---@return { imported: integer, skipped: integer }|nil
function StatsDB.replaceSynced(source_id, replace, rows)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return nil
    end
    Base.ensure()
    if not Base.exec("BEGIN IMMEDIATE;") then
        return nil
    end
    local result = { imported = 0, skipped = 0 }
    local ok, err = pcall(function()
        if type(replace) == "table" then
            if replace.mode == "prefix" and type(replace.stable_prefixes) == "table" then
                for _, prefix in ipairs(replace.stable_prefixes) do
                    assert(StatsDB.deleteSyncedByStablePrefix(source_id, prefix),
                        "failed to clear synced reading stats")
                end
            else
                assert(StatsDB.deleteSyncedBySource(source_id), "failed to clear synced reading stats")
            end
        end
        for _, row in ipairs(rows or {}) do
            local duplicate = StatsDB.exists(row)
            assert(StatsDB.add(row, true), "failed to save pulled reading stats")
            if duplicate then
                result.skipped = result.skipped + 1
            else
                result.imported = result.imported + 1
            end
        end
    end)
    if not ok then
        Base.exec("ROLLBACK;")
        logger.warn("book.db replaceSynced failed", err)
        return nil
    end
    if not Base.exec("COMMIT;") then
        Base.exec("ROLLBACK;")
        return nil
    end
    return result
end

--- 汇总某源阅读统计：总时长/页数、近 7 天时长、最长单日。
---@param source_id string
---@return { total_seconds: number, total_pages: number, last7_seconds: number, longest_day_seconds: number }
function StatsDB.summaryBySource(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return { total_seconds = 0, total_pages = 0, last7_seconds = 0, longest_day_seconds = 0 }
    end
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
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return { total_seconds = 0, pages = 0, last_read = 0 }
    end
    Base.ensure()
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
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return {}
    end
    Base.ensure()
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
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT date(start_time,'unixepoch','localtime') AS day,
                 stable_id, SUM(duration), MAX(page), MAX(total_pages)
          FROM reading_stats WHERE source_id=?
            AND stable_id NOT GLOB '__*:day:*'
            AND stable_id NOT GLOB '__*:book:*'
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
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return { total_seconds = 0, book_count = 0, pages = 0 }
    end
    Base.ensure()
    local seconds, books, pages = Base.rowexec(
        [[SELECT COALESCE(SUM(duration),0), COUNT(DISTINCT stable_id), COUNT(*)
          FROM reading_stats WHERE source_id=? AND start_time>=? AND start_time<?;]],
        source_id, tonumber(start_ts) or 0, tonumber(end_ts) or 0
    )
    return {
        total_seconds = tonumber(seconds) or 0,
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
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT r.stable_id, b.title, b.authors, b.percent,
                 SUM(r.duration), COUNT(*)
          FROM reading_stats r LEFT JOIN books b
            ON b.source_id=r.source_id AND b.stable_id=r.stable_id
          WHERE r.source_id=? AND r.start_time>=? AND r.start_time<?
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
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT date(start_time,'unixepoch','localtime'), SUM(duration), COUNT(*)
          FROM reading_stats WHERE source_id=? AND start_time>=? AND start_time<?
          GROUP BY 1 ORDER BY 1;]],
        source_id, tonumber(start_ts) or 0, tonumber(end_ts) or 0
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

--- 指定时间范围内某源的逐小时统计（本地时区 0–23）。
---@param source_id string
---@param start_ts number
---@param end_ts number
---@return table[] rows { hour, seconds, pages }（hour 为 0–23）
function StatsDB.periodHours(source_id, start_ts, end_ts)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER),
                 SUM(duration), COUNT(*)
          FROM reading_stats WHERE source_id=? AND start_time>=? AND start_time<?
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
    if type(ids) ~= "table" or #ids == 0 then
        return false
    end
    Base.ensure()
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
