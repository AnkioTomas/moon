--[[--
reading_stats 表：自采集与拉取的阅读统计（逐页事件、云端分桶及权威累计值，按记录身份去重）。

sync_status=0 表示待上传，1 表示已与远端同步。

身份即 BookIdentity(source_id + stable_id)，天然按源隔离。

@module koplugin.book.db.stats
--]]

local Base = require("db.base")
local logger = require("utils.log")

local StatsDB = {}

local DAY_RECORD = "day"
local ROLLUP_RECORD = "page_rollup"
local LOCAL_RECORDS = { page = true, [ROLLUP_RECORD] = true }

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
  chapter_fraction REAL, sync_status INTEGER NOT NULL DEFAULT 0,
  event_count INTEGER NOT NULL DEFAULT 1,
  last_time INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_reading_stats_time ON reading_stats(source_id, start_time);
]]) then return false end

    local columns, nrows = Base.query("PRAGMA table_info(reading_stats);")
    if columns then
        local present = {}
        for i = 1, nrows do
            present[columns[2][i]] = true
        end
        for _, column in ipairs({
            { "event_count", "event_count INTEGER NOT NULL DEFAULT 1" },
            { "last_time", "last_time INTEGER NOT NULL DEFAULT 0" },
        }) do
            if not present[column[1]]
                and not Base.exec("ALTER TABLE reading_stats ADD COLUMN " .. column[2] .. ";") then
                return false
            end
        end
    end

    -- v1 身份漏了 record_type，单行压缩会与原 page 行碰撞后被删除。
    if not Base.exec([[DROP INDEX IF EXISTS idx_reading_stats_identity;
CREATE UNIQUE INDEX IF NOT EXISTS idx_reading_stats_identity_v2
  ON reading_stats(source_id, stable_id, record_type, page, start_time, duration);
CREATE UNIQUE INDEX IF NOT EXISTS idx_reading_stats_rollup_bucket
  ON reading_stats(source_id, stable_id, record_type, start_time)
  WHERE record_type='page_rollup';]]) then
        return false
    end
    return true
end

--- 删除本地阅读统计。
--- 这是纯本地操作，不会触碰远端；缺少 stable_id 时按源清除，
--- 传入时间范围时使用半开区间 [from_ts, to_ts)。
---@param source_id string
---@param stable_id string|nil nil=当前源全部
---@param from_ts number|nil 起始时间（含）
---@param to_ts number|nil 结束时间（不含）
---@return boolean
function StatsDB.deleteLocal(source_id, stable_id, from_ts, to_ts)
    if type(source_id) ~= "string" or source_id == "" then
        return false
    end
    local where = { "source_id=?" }
    local args = { source_id }
    if stable_id ~= nil then
        if type(stable_id) ~= "string" or stable_id == "" then return false end
        where[#where + 1] = "stable_id=?"
        args[#args + 1] = stable_id
    end
    if from_ts ~= nil or to_ts ~= nil then
        local from_n, to_n = tonumber(from_ts), tonumber(to_ts)
        if not from_n or not to_n or to_n <= from_n then return false end
        where[#where + 1] = "start_time>=?"
        where[#where + 1] = "start_time<?"
        args[#args + 1] = from_n
        args[#args + 1] = to_n
    end
    return Base.exec("DELETE FROM reading_stats WHERE " .. table.concat(where, " AND ") .. ";", unpack(args)) ~= nil
end

--- 云端 pull 覆盖前的清理：**只删本次回包时间窗口内的合成行**。
---
--- 两条边界都是数据事故的教训，不能放宽：
--- 1. 只删合成行（`__*:day:*` / `__*:book:*` / `__*:total*`）。本地逐页记录推送成功后也是
---    `sync_status=1`，按 sync_status 删会把用户自己设备采集的阅读历史一起删掉。
--- 2. 只删窗口内。回包通常只覆盖近一个月，删整源等于每同步一次就抹掉更早的历史。
---@param source_id string
---@param from_ts number 窗口起（含）
---@param to_ts number 窗口止（含）
---@param prefix string|nil 限定 stable_id 前缀；缺省则窗口内全部合成行
---@return boolean
function StatsDB.deleteSyntheticInRange(source_id, from_ts, to_ts, prefix)
    local from_n = tonumber(from_ts)
    local to_n = tonumber(to_ts)
    if not from_n or not to_n then
        return false
    end
    local sql = [[DELETE FROM reading_stats
          WHERE source_id=? AND record_type IN ('day','book','total')
            AND start_time>=? AND start_time<=?]]
    if prefix ~= nil then
        return Base.exec(sql .. " AND stable_id LIKE ?;", source_id, from_n, to_n, prefix .. "%") ~= nil
    end
    return Base.exec(sql .. ";", source_id, from_n, to_n) ~= nil
end

--- 按 500 一批执行 `<prefix> WHERE id IN (…)`；任一批失败即返回 false（事务由调用方管）。
---@param prefix string
---@param ids number[]
---@return boolean
local function execByIds(prefix, ids)
    for start = 1, #ids, 500 do
        local batch = { unpack(ids, start, math.min(start + 499, #ids)) }
        if not Base.exec(
            prefix .. " WHERE id IN (" .. string.rep("?", #batch, ",") .. ");",
            unpack(batch)
        ) then
            return false
        end
    end
    return true
end

--- 本地记录是否已含在拉取时间为 at 的云端快照之外：未上传，或快照之后才读。
--- at=0（旧版拉取未记时间）只认未上传，宁可少算也不双计。两个 ? 都绑 at。
local FRESH_LOCAL = "(sync_status=0 OR (?>0 AND start_time>=?))"

--- 按天合并云端日桶与本地页记录：有云端日桶的日期 = 云端 + 拉取后本地新读的。
---@param source_id string
---@param start_ts number|nil 可选时间范围（含）
---@param end_ts number|nil 可选时间范围（不含）
---@return table[] rows { ymd, seconds, pages }
local function mergedDailyRowsOne(source_id, start_ts, end_ts)
    local fetched_at = tonumber(Base.rowexec(
        "SELECT MAX(last_time) FROM reading_stats WHERE source_id=? AND record_type='day';",
        source_id
    )) or 0
    local range = ""
    local args = { fetched_at, fetched_at, source_id }
    if start_ts and end_ts then
        range = " AND start_time>=? AND start_time<?"
        args[4] = tonumber(start_ts) or 0
        args[5] = tonumber(end_ts) or 0
    end
    local result, nrows = Base.query(
        [[SELECT date(start_time,'unixepoch','localtime') AS day,
                 stable_id, record_type, COALESCE(SUM(duration),0),
                 COALESCE(SUM(event_count),0),
                 COALESCE(SUM(CASE WHEN ]] .. FRESH_LOCAL .. [[ THEN duration ELSE 0 END),0)
          FROM reading_stats WHERE source_id=?]] .. range .. [[
          GROUP BY day, stable_id, record_type ORDER BY day;]],
        unpack(args)
    )
    local cloud, local_days, fresh, pages = {}, {}, {}, {}
    for i = 1, nrows do
        local day = result[1][i]
        local record_type = result[3][i]
        local seconds = tonumber(result[4][i]) or 0
        local count = tonumber(result[5][i]) or 0
        -- 周期书单、累计值、单书明细（book / total / book_total / book_day）都不参与日历总时长
        if record_type == DAY_RECORD then
            cloud[day] = seconds
            pages[day] = (pages[day] or 0) + count
        elseif LOCAL_RECORDS[record_type] then
            local_days[day] = (local_days[day] or 0) + seconds
            fresh[day] = (fresh[day] or 0) + (tonumber(result[6][i]) or 0)
            pages[day] = (pages[day] or 0) + count
        end
    end
    local seen, rows = {}, {}
    for day, seconds in pairs(cloud) do
        seen[day] = true
        rows[#rows + 1] = { ymd = day, seconds = seconds + (fresh[day] or 0), pages = pages[day] or 0 }
    end
    for day, seconds in pairs(local_days) do
        if not seen[day] then
            rows[#rows + 1] = { ymd = day, seconds = seconds, pages = pages[day] or 0 }
        end
    end
    table.sort(rows, function(a, b) return a.ymd < b.ymd end)
    return rows
end

--- 按天合并云端日桶与本地逐页记录；多源时先单源合并再按日相加。
---@param source_id string|string[]
---@param start_ts number|nil
---@param end_ts number|nil
---@return table[]
local function mergedDailyRows(source_id, start_ts, end_ts)
    if type(source_id) ~= "table" then
        return mergedDailyRowsOne(source_id, start_ts, end_ts)
    end
    local by_day = {}
    for _, id in ipairs(source_id) do
        for _, row in ipairs(mergedDailyRowsOne(id, start_ts, end_ts)) do
            local cur = by_day[row.ymd] or { ymd = row.ymd, seconds = 0, pages = 0 }
            cur.seconds = cur.seconds + row.seconds
            cur.pages = cur.pages + row.pages
            by_day[row.ymd] = cur
        end
    end
    local rows = {}
    for _, row in pairs(by_day) do
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b) return a.ymd < b.ymd end)
    return rows
end

--- 追加一条阅读统计。
---@param row BookStatsRow
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
            chapter_idx, chapter_fraction, sync_status, event_count, last_time
          ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(source_id, stable_id, record_type, page, start_time, duration)
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
        synced and 1 or 0,
        math.max(1, tonumber(row.event_count) or 1),
        tonumber(row.last_time) or 0
    ) ~= nil
end

--- 列出指定源的待上传统计。
---@param source_id string
---@param limit number|nil
---@return table[]
function StatsDB.unsyncedBySource(source_id, limit)
    local result, nrows = Base.query(
        [[SELECT id, stable_id, page, start_time, duration, total_pages,
                 chapter_idx, chapter_fraction, sync_status
          FROM reading_stats WHERE source_id=? AND sync_status=0
          ORDER BY start_time ASC, id ASC LIMIT ?;]],
        source_id, math.max(1, tonumber(limit) or 500)
    )
    local rows = {}
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
    return rows
end

--- 记录是否已存在（命中记录身份唯一索引）。
---@param row table
---@return boolean
function StatsDB.exists(row)
    local source_id = row.source_id
    return Base.rowexec(
        [[SELECT 1 FROM reading_stats
          WHERE source_id=? AND stable_id=? AND record_type=? AND page=?
            AND start_time=? AND duration=? LIMIT 1;]],
        source_id,
        row.stable_id,
        row.record_type,
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
---@return { imported: integer, skipped: integer, failed: integer|nil }|nil
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
        if replace and replace.mode == "all_synced" then
            return Base.exec(
                "DELETE FROM reading_stats WHERE source_id=? AND sync_status=1;",
                source_id
            ) ~= nil
        end
        if replace and type(replace.ranges) == "table" then
            for _, range in ipairs(replace.ranges) do
                if not StatsDB.deleteSyntheticInRange(
                    source_id, range.from_ts, range.to_ts, range.stable_prefix
                ) then return false end
            end
            return true
        end
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
    local ok = true
    -- 单书明细按 stable_id 精确整本替换：不走前缀，书 id 可能互为前缀
    for _, stable_id in ipairs(replace and replace.books or {}) do
        ok = Base.exec(
            [[DELETE FROM reading_stats WHERE source_id=? AND stable_id=?
                AND record_type IN ('book_day','book_total');]],
            source_id, stable_id
        ) ~= nil
        if not ok then break end
    end
    ok = ok and clearRange()
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
--- source_id 可为单源字符串，或已启用源 id 列表（混合模式）。
---@param source_id string|string[]
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
    local remote_total = 0
    -- 权威 total 是单源语义（微信）；混合跨源只用合并日桶。
    if type(source_id) == "string" then
        remote_total = tonumber(Base.rowexec(
            [[SELECT COALESCE(MAX(duration),0) FROM reading_stats
              WHERE source_id=? AND record_type='total';]],
            source_id
        )) or 0
    end
    if remote_total > 0 then total_seconds = remote_total end
    return {
        total_seconds = total_seconds,
        total_pages = total_pages,
        last7_seconds = last7_seconds,
        longest_day_seconds = longest_day_seconds,
    }
end

--- 汇总单本书阅读统计：总时长/已读页数/上次阅读时间（详情页用）。
--- 有云端单书快照（book_total）时，总时长 = 快照 + 快照后读的 + 仍未上传的本地时长；
--- 快照前已上传的本地时长已含在快照里，不能再加。没有快照时就是本地累计。
---@param source_id string
---@param stable_id string
---@return { total_seconds: number, pages: number, last_read: number }
function StatsDB.summaryByBook(source_id, stable_id)
    local snapshot, fetched_at = Base.rowexec(
        [[SELECT duration, start_time FROM reading_stats
          WHERE source_id=? AND stable_id=? AND record_type='book_total' LIMIT 1;]],
        source_id,
        stable_id
    )
    local local_seconds, fresh_seconds, pages, last_read = Base.rowexec(
        [[SELECT COALESCE(SUM(duration),0),
                 COALESCE(SUM(CASE WHEN sync_status=0 OR start_time>=? THEN duration ELSE 0 END),0),
                 COALESCE(SUM(event_count),0),
                 COALESCE(MAX(CASE WHEN record_type='page_rollup'
                    THEN last_time ELSE start_time END),0)
          FROM reading_stats WHERE source_id=? AND stable_id=?
            AND record_type IN ('page','page_rollup');]],
        tonumber(fetched_at) or 0,
        source_id,
        stable_id
    )
    local total_seconds = tonumber(local_seconds) or 0
    if snapshot then
        total_seconds = tonumber(snapshot) + (tonumber(fresh_seconds) or 0)
    end
    return {
        total_seconds = total_seconds,
        pages = tonumber(pages) or 0,
        last_read = tonumber(last_read) or 0,
    }
end

--- 云端单书累计快照：stable_id → 秒（判断哪些书需要重拉按日明细）。
---@param source_id string
---@return table<string, number>
function StatsDB.bookTotals(source_id)
    local result, nrows = Base.query(
        "SELECT stable_id, duration FROM reading_stats WHERE source_id=? AND record_type='book_total';",
        source_id
    )
    local out = {}
    for i = 1, nrows do
        out[result[1][i]] = tonumber(result[2][i]) or 0
    end
    return out
end

--- 按（书，天）合并云端 book_day 与本地逐页记录，产出 CTE
--- ``bd(source_id, stable_id, day, seconds, pages, max_page, max_total_pages)``：
--- 某书某天有云端值 = 云端 + 这本书拉取后本地新读 / 未上传的；否则只有本地。
---@param source_id string|string[]
---@param filter string 追加到 WHERE 的片段，列名用 ``r.`` 前缀；作用于云端与本地两侧
---@param filter_args any[]
---@return string sql 以 WITH 开头，调用方接 SELECT … FROM bd
---@return any[] args
local function bookDays(source_id, filter, filter_args)
    local src, src_args = Base.sourceClause("r.source_id", source_id)
    local args = {}
    for _, list in ipairs({ src_args, filter_args, src_args, src_args, filter_args }) do
        for _, v in ipairs(list) do args[#args + 1] = v end
    end
    return [[WITH cloud AS (
          SELECT r.source_id, r.stable_id, date(r.start_time,'unixepoch','localtime') AS day,
                 SUM(r.duration) AS seconds
          FROM reading_stats r WHERE ]] .. src .. [[ AND r.record_type='book_day']] .. filter .. [[
          GROUP BY 1, 2, 3),
        fetched AS (
          SELECT r.source_id, r.stable_id, MAX(r.last_time) AS at
          FROM reading_stats r WHERE ]] .. src .. [[ AND r.record_type='book_day'
          GROUP BY 1, 2),
        loc AS (
          SELECT r.source_id, r.stable_id, date(r.start_time,'unixepoch','localtime') AS day,
                 SUM(r.duration) AS seconds,
                 SUM(CASE WHEN r.sync_status=0 OR r.start_time>=f.at THEN r.duration ELSE 0 END) AS fresh,
                 SUM(r.event_count) AS pages, MAX(r.page) AS max_page,
                 MAX(r.total_pages) AS max_total_pages
          FROM reading_stats r LEFT JOIN fetched f
            ON f.source_id=r.source_id AND f.stable_id=r.stable_id
          WHERE ]] .. src .. [[ AND r.record_type IN ('page','page_rollup')]] .. filter .. [[
          GROUP BY 1, 2, 3),
        bd AS (
          SELECT l.source_id, l.stable_id, l.day,
                 CASE WHEN c.seconds IS NULL THEN l.seconds ELSE c.seconds + l.fresh END AS seconds,
                 l.pages, l.max_page, l.max_total_pages
          FROM loc l LEFT JOIN cloud c
            ON c.source_id=l.source_id AND c.stable_id=l.stable_id AND c.day=l.day
          UNION ALL
          SELECT c.source_id, c.stable_id, c.day, c.seconds, 0, 0, 0
          FROM cloud c LEFT JOIN loc l
            ON l.source_id=c.source_id AND l.stable_id=c.stable_id AND l.day=c.day
          WHERE l.day IS NULL)
        ]], args
end

--- 单本书按天聚合（详情页「最近几天」、锁屏日桶用，最近在前），含云端其他设备的按日时长。
---@param source_id string
---@param stable_id string
---@param limit number|nil 最多返回天数，默认 5
---@return table[] rows { ymd, seconds, pages }（日期倒序）
function StatsDB.dailyByBook(source_id, stable_id, limit)
    local cte, args = bookDays(source_id, " AND r.stable_id=?", { stable_id })
    args[#args + 1] = tonumber(limit) or 5
    local result, nrows = Base.query(
        cte .. "SELECT day, seconds, pages FROM bd ORDER BY day DESC LIMIT ?;",
        unpack(args)
    )
    local rows = {}
    for i = 1, nrows do
        rows[#rows + 1] = {
            ymd = result[1][i],
            seconds = tonumber(result[2][i]) or 0,
            pages = tonumber(result[3][i]) or 0,
        }
    end
    return rows
end

--- 按天聚合某源阅读统计（本地洞察日历用）。
---@param source_id string|string[]
---@return table[] rows { ymd, seconds, pages }（按日期升序）
function StatsDB.dailyBySource(source_id)
    return mergedDailyRows(source_id)
end

--- 按天按书聚合某源阅读统计（本地洞察当日书单用），含云端单书按日时长。
--- 进度近似 = 当日读到最深页 / 当时总页数；只有云端时长的那天没有页坐标，两者为 0。
---@param source_id string|string[]
---@return table[] rows { ymd, source_id, stable_id, seconds, max_page, max_total_pages }（日期升序、时长降序）
function StatsDB.dailyBooksBySource(source_id)
    local cte, args = bookDays(source_id, "", {})
    local result, nrows = Base.query(
        cte .. [[SELECT day, source_id, stable_id, seconds, max_page, max_total_pages
          FROM bd ORDER BY day, seconds DESC;]],
        unpack(args)
    )
    local rows = {}
    for i = 1, nrows do
        rows[#rows + 1] = {
            ymd = result[1][i],
            source_id = result[2][i],
            stable_id = result[3][i],
            seconds = tonumber(result[4][i]) or 0,
            max_page = tonumber(result[5][i]) or 0,
            max_total_pages = tonumber(result[6][i]) or 0,
        }
    end
    return rows
end

--- 指定时间范围内某源的账单汇总。
---@param source_id string|string[]
---@param start_ts number
---@param end_ts number
---@return { total_seconds: number, book_count: number, pages: number }
function StatsDB.periodSummary(source_id, start_ts, end_ts)
    -- 书数按（书，天）合并口径（含其他设备读过的书），页数只有本地记录；
    -- 总时长按天走账户日桶合并口径，与洞察日历保持一致。
    local cte, args = bookDays(source_id, " AND r.start_time>=? AND r.start_time<?",
        { tonumber(start_ts) or 0, tonumber(end_ts) or 0 })
    local books, pages = Base.rowexec(
        cte .. [[SELECT COUNT(DISTINCT source_id || '\0' || stable_id), COALESCE(SUM(pages),0)
          FROM bd;]],
        unpack(args)
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
---@param source_id string|string[]
---@param start_ts number
---@param end_ts number
---@param limit number|nil
---@return table[] rows { source_id, stable_id, title, authors, percent, seconds, pages }
function StatsDB.periodBooks(source_id, start_ts, end_ts, limit)
    local cte, args = bookDays(source_id, " AND r.start_time>=? AND r.start_time<?",
        { tonumber(start_ts) or 0, tonumber(end_ts) or 0 })
    args[#args + 1] = math.max(1, tonumber(limit) or 5)
    local result, nrows = Base.query(
        cte .. [[SELECT bd.source_id, bd.stable_id, b.title, b.authors,
                 COALESCE(p.fraction * 100, 0),
                 SUM(bd.seconds), SUM(bd.pages)
          FROM bd LEFT JOIN books b
            ON b.source_id=bd.source_id AND b.stable_id=bd.stable_id
          LEFT JOIN pending_progress p
            ON p.source_id=bd.source_id AND p.stable_id=bd.stable_id
          GROUP BY bd.source_id, bd.stable_id ORDER BY 6 DESC LIMIT ?;]],
        unpack(args)
    )
    local rows = {}
    for i = 1, nrows do
        rows[#rows + 1] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            title = result[3][i],
            authors = result[4][i],
            percent = tonumber(result[5][i]) or 0,
            seconds = tonumber(result[6][i]) or 0,
            pages = tonumber(result[7][i]) or 0,
        }
    end
    return rows
end

--- 把较老的已同步逐页记录按书籍和本地小时压成汇总行。
--- 未同步行绝不参与；event_count 保留原页事件数，所有展示聚合口径不变。
---@param source_id string
---@param before_ts number
---@param limit number|nil
---@return integer|nil compacted 原始行数；失败返回 nil
function StatsDB.compactSynced(source_id, before_ts, limit)
    local result, nrows = Base.query(
        [[SELECT id, stable_id, page, start_time, duration, total_pages, event_count
          FROM reading_stats
          WHERE source_id=? AND sync_status=1 AND record_type='page' AND start_time<?
          ORDER BY start_time ASC, id ASC LIMIT ?;]],
        source_id, tonumber(before_ts) or 0, math.max(1, tonumber(limit) or 1000)
    )
    if nrows == 0 then return 0 end

    local groups, order, ids = {}, {}, {}
    for i = 1, nrows do
        local ts = tonumber(result[4][i]) or 0
        local clock = os.date("*t", ts)
        ---@cast clock osdate
        clock.min, clock.sec = 0, 0
        local hour = os.time(clock)
        local stable_id = result[2][i]
        local key = stable_id .. "\31" .. tostring(hour)
        local group = groups[key]
        if not group then
            group = {
                source_id = source_id, stable_id = stable_id,
                record_type = ROLLUP_RECORD, page = 0, start_time = hour,
                duration = 0, total_pages = 0, event_count = 0,
                last_time = ts,
            }
            groups[key] = group
            order[#order + 1] = group
        end
        group.page = math.max(group.page, tonumber(result[3][i]) or 0)
        group.last_time = math.max(group.last_time, ts)
        group.duration = group.duration + (tonumber(result[5][i]) or 0)
        group.total_pages = math.max(group.total_pages, tonumber(result[6][i]) or 0)
        group.event_count = group.event_count + math.max(1, tonumber(result[7][i]) or 1)
        ids[#ids + 1] = tonumber(result[1][i])
    end

    if not Base.exec("BEGIN IMMEDIATE;") then return nil end
    local ok = true
    for _, group in ipairs(order) do
        if not Base.exec(
            [[INSERT INTO reading_stats (
                source_id, stable_id, record_type, page, start_time, duration,
                total_pages, sync_status, event_count, last_time
              ) VALUES (?,?,?,?,?,?,?,?,?,?)
              ON CONFLICT(source_id, stable_id, record_type, start_time)
                WHERE record_type='page_rollup'
              DO UPDATE SET
                page=MAX(reading_stats.page, excluded.page),
                duration=reading_stats.duration + excluded.duration,
                total_pages=MAX(reading_stats.total_pages, excluded.total_pages),
                event_count=reading_stats.event_count + excluded.event_count,
                last_time=MAX(reading_stats.last_time, excluded.last_time);]],
            group.source_id, group.stable_id, group.record_type, group.page,
            group.start_time, group.duration, group.total_pages, 1,
            group.event_count, group.last_time
        ) then
            ok = false
            break
        end
    end
    ok = ok and execByIds("DELETE FROM reading_stats", ids)
    if ok and Base.exec("COMMIT;") then return #ids end
    Base.exec("ROLLBACK;")
    return nil
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
    if execByIds("UPDATE reading_stats SET sync_status=1", ids) and Base.exec("COMMIT;") then
        return true
    end
    Base.exec("ROLLBACK;")
    return false
end

return StatsDB
