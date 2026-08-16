--[[--
reading_stats 表：自采集阅读统计（一页一条，上传成功即删）

身份即 BookRef(source_id + stable_id)，天然按源隔离。

@module koplugin.book.utils.db.stats
--]]

local Base = require("utils.db.base")

local StatsDB = {}

--- 追加一条阅读统计。
---@param row { source_id: string, stable_id: string, page: number, start_time: number, duration: number, total_pages: number }
---@return boolean
function StatsDB.add(row)
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
        [[INSERT INTO reading_stats (source_id, stable_id, page, start_time, duration, total_pages)
          VALUES (?,?,?,?,?,?);]],
        source_id,
        row.stable_id,
        tonumber(row.page) or 0,
        start_time,
        duration,
        tonumber(row.total_pages) or 0
    ) ~= nil
end

--- 指定源的待上报条数。
---@param source_id string
---@return number
function StatsDB.countBySource(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return 0
    end
    Base.ensure()
    local n = Base.rowexec(
        [[SELECT COUNT(*) FROM reading_stats WHERE source_id=?;]],
        source_id
    )
    return tonumber(n) or 0
end

--- 列出指定源的待上报统计（按时间升序）。
---@param source_id string
---@return table[] rows 含 id / stable_id / page / start_time / duration / total_pages
function StatsDB.allBySource(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT id, stable_id, page, start_time, duration, total_pages
          FROM reading_stats WHERE source_id=? ORDER BY start_time ASC;]],
        source_id
    )
    if not result or nrows == 0 then
        return {}
    end
    local rows = {}
    for i = 1, nrows do
        rows[#rows + 1] = {
            id = tonumber(result[1][i]) or 0,
            stable_id = result[2][i],
            page = tonumber(result[3][i]) or 0,
            start_time = tonumber(result[4][i]) or 0,
            duration = tonumber(result[5][i]) or 0,
            total_pages = tonumber(result[6][i]) or 0,
        }
    end
    return rows
end

--- 汇总某源阅读统计：总时长/页数、近 7 天时长、最长单日。
---@param source_id string
---@return { total_seconds: number, total_pages: number, last7_seconds: number, longest_day_seconds: number }
function StatsDB.summaryBySource(source_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return { total_seconds = 0, total_pages = 0, last7_seconds = 0, longest_day_seconds = 0 }
    end
    Base.ensure()
    local total_seconds, total_pages = Base.rowexec(
        [[SELECT COALESCE(SUM(duration),0), COUNT(*) FROM reading_stats WHERE source_id=?;]],
        source_id
    )
    local last7 = Base.rowexec(
        [[SELECT COALESCE(SUM(duration),0) FROM reading_stats
          WHERE source_id=? AND start_time >= strftime('%s','now','localtime','start of day','-6 days');]],
        source_id
    )
    local longest = Base.rowexec(
        [[SELECT COALESCE(MAX(day_total),0) FROM (
            SELECT SUM(duration) AS day_total FROM reading_stats
            WHERE source_id=? GROUP BY date(start_time,'unixepoch','localtime'));]],
        source_id
    )
    return {
        total_seconds = tonumber(total_seconds) or 0,
        total_pages = tonumber(total_pages) or 0,
        last7_seconds = tonumber(last7) or 0,
        longest_day_seconds = tonumber(longest) or 0,
    }
end

--- 汇总单本书阅读统计：总时长/已读页数/上次阅读时间（详情页用）。
--- 注意：远端源统计上报成功即删，这里只剩未上报部分；本地源完整保留。
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
--- 注意：远端源统计上报成功即删，这里只剩未上报部分；本地源完整保留。
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
    source_id = Base.requireSourceId(source_id)
    if not source_id then
        return {}
    end
    Base.ensure()
    local result, nrows = Base.query(
        [[SELECT date(start_time,'unixepoch','localtime') AS day,
                 SUM(duration), COUNT(*)
          FROM reading_stats WHERE source_id=? GROUP BY day ORDER BY day;]],
        source_id
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

--- 删除已上传记录。
---@param ids number[]
---@return boolean
function StatsDB.deleteIds(ids)
    if type(ids) ~= "table" or #ids == 0 then
        return false
    end
    Base.ensure()
    for _, id in ipairs(ids) do
        Base.exec([[DELETE FROM reading_stats WHERE id=?;]], tonumber(id) or 0)
    end
    return true
end

return StatsDB
