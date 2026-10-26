--[[--
reading_stats 表：自采集与拉取的阅读统计（逐页事件、云端分桶及权威累计值，按记录身份去重）。

sync_status=0 表示待上传，1 表示已与远端同步，2 表示从 KOReader 统计导入（不上传，pull 的
按 sync_status=1 清理也删不到它）。

身份即 BookIdentity(source_id + stable_id)，天然按源隔离。

record_type：page / page_rollup 为本地采集；day / hour / total 为账户合成桶；book_total / book_day 为云端单书
（stable_id 为真实书 id）；cloud_session 为云端单条阅读会话（给「阅读记录」列表；event_count 参与
单书 / 按天页数汇总 —— 漫画是本次新推进的页数，其他格式是 pagesRead；时长不参与）；book 为旧版周排行，已不再写入。

不变量：
  - 身份唯一索引必须含 record_type（v1 漏了会让压缩撞删 page）。
  - pull 只删合成行，且只删回包时间窗；按 sync_status 全删会吞掉已上传的本地历史。
  - replaceSynced 空 rows 什么都不删；replace.books 按 stable_id 精确删，不用 LIKE（4 / 42 互为前缀）。
  - 合并口径：有云端值 = 云端 + 本地（sync_status=0 或 start_time ≥ 拉取时间）；否则只有本地。
    云端单书按日求和不等于累计，两者不互推。
书改名 / 收编时由 books_db 调 moveIdentity 迁身份。

@module koplugin.book.book.stats_db
--]]

local DB = require("utils.db")
local logger = require("utils.log")
require("book.books_db")
require("book.progress_db")

local StatsDB = {
    PENDING = 0,
    SYNCED = 1,
    IMPORTED = 2,
}

local DAY_RECORD = "day"
local HOUR_RECORD = "hour"
local ROLLUP_RECORD = "page_rollup"
--- 云端单条阅读会话：详情 / 统计页「阅读记录」列出真实起止时段用。
local SESSION_RECORD = "cloud_session"
local LOCAL_RECORDS = { page = true, [ROLLUP_RECORD] = true }

DB.schema("reading_stats", function()
    if not DB.exec([[
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

    local columns, nrows = DB.query("PRAGMA table_info(reading_stats);")
    if columns then
        local present = {}
        for i = 1, nrows do
            present[columns[2][i]] = true
        end
        for _idx, column in ipairs({
            { "event_count", "event_count INTEGER NOT NULL DEFAULT 1" },
            { "last_time", "last_time INTEGER NOT NULL DEFAULT 0" },
        }) do
            if not present[column[1]]
                and not DB.exec("ALTER TABLE reading_stats ADD COLUMN " .. column[2] .. ";") then
                return false
            end
        end
    end

    -- v1 身份漏了 record_type，单行压缩会与原 page 行碰撞后被删除。
    if not DB.exec([[DROP INDEX IF EXISTS idx_reading_stats_identity;
CREATE UNIQUE INDEX IF NOT EXISTS idx_reading_stats_identity_v2
  ON reading_stats(source_id, stable_id, record_type, page, start_time, duration);
CREATE UNIQUE INDEX IF NOT EXISTS idx_reading_stats_rollup_bucket
  ON reading_stats(source_id, stable_id, record_type, start_time)
  WHERE record_type='page_rollup';]]) then
        return false
    end
    return true
end)

--- 书改名 / 收编时由 books_db 调用。
function StatsDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    return DB.moveIdentity("reading_stats", source_id, old_stable_id, new_stable_id, merge)
end

--- 书被删（墓碑撕掉）时由 books_db 调用。
function StatsDB.removeIdentity(source_id, stable_id)
    return DB.removeIdentity("reading_stats", source_id, stable_id)
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
    ---@type (string|number)[]
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
    return DB.exec("DELETE FROM reading_stats WHERE " .. table.concat(where, " AND ") .. ";", unpack(args)) ~= nil
end

--- 云端 pull 覆盖前的清理：**只删本次回包时间窗口内的合成行**。
---
--- 两条边界都是数据事故的教训，不能放宽：
--- 1. 只删合成行（`__*:day:*` / `__*:hour:*` / `__*:book:*` / `__*:total*`）。本地逐页记录推送成功后也是
---    `sync_status=1`，按 sync_status 删会把用户自己设备采集的阅读历史一起删掉。
--- 2. 只删窗口内。回包通常只覆盖近一个月，删整源等于每同步一次就抹掉更早的历史。
---@param source_id string
---@param from_ts number 窗口起（含）
---@param to_ts number 窗口止（含）
---@param prefix string|nil 限定 stable_id 前缀；缺省则窗口内全部合成行
---@return boolean
local function deleteSyntheticInRange(source_id, from_ts, to_ts, prefix)
    local from_n = tonumber(from_ts)
    local to_n = tonumber(to_ts)
    if not from_n or not to_n then
        return false
    end
    local sql = [[DELETE FROM reading_stats
          WHERE source_id=? AND record_type IN ('day','hour','book','total')
            AND start_time>=? AND start_time<=?]]
    if prefix ~= nil then
        return DB.exec(sql .. " AND stable_id LIKE ?;", source_id, from_n, to_n, prefix .. "%") ~= nil
    end
    return DB.exec(sql .. ";", source_id, from_n, to_n) ~= nil
end

--- 按 500 一批执行 `<prefix> WHERE id IN (…)`；任一批失败即返回 false（事务由调用方管）。
---@param prefix string
---@param ids number[]
---@return boolean
local function execByIds(prefix, ids)
    for start = 1, #ids, 500 do
        local batch = { unpack(ids, start, math.min(start + 499, #ids)) }
        if not DB.exec(
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

--- 同一条规则，但引用 `WITH f(at) AS (SELECT ?)` 里的列：一条语句里要用好几次时，
--- 不必重复绑 ?（多绑一次就多一个容易错位的参数）。
local FRESH_LOCAL_AT = "(sync_status=0 OR (f.at>0 AND start_time>=f.at))"

--- 按天合并云端日桶与本地页记录：有云端日桶的日期 = 云端 + 拉取后本地新读的。
--- 源配置 merge_local_stats 打开时每天取它与本地当天合计中较大的：补上云端没记到的离线阅读。
--- 云端只有日合计、没有逐条记录，分不出哪段已上报，较大值是不双计的近似；extra 是比云端优先多出的秒数。
---@param source_id string
---@param start_ts number|nil 可选时间范围（含）
---@param end_ts number|nil 可选时间范围（不含）
---@return table[] rows { ymd, seconds, pages, extra }
local function mergedDailyRowsOne(source_id, start_ts, end_ts)
    local fetched_at = tonumber(DB.rowexec(
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
    local result, nrows = DB.query(
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
    local merge = require("utils.settings").getSource(source_id).merge_local_stats == true
    local seen, rows = {}, {}
    for day, seconds in pairs(cloud) do
        seen[day] = true
        local merged = seconds + (fresh[day] or 0)
        local extra = merge and math.max(0, (local_days[day] or 0) - merged) or 0
        rows[#rows + 1] = { ymd = day, seconds = merged + extra, pages = pages[day] or 0, extra = extra }
    end
    -- 没有云端日桶的日期（云端当天为 0）本来就全用本地；总时长另以云端 total 为准，拉取前读的才算多出。
    for day, seconds in pairs(local_days) do
        if not seen[day] then
            rows[#rows + 1] = { ymd = day, seconds = seconds, pages = pages[day] or 0,
                extra = merge and seconds - (fresh[day] or 0) or 0 }
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
    for _idx, id in ipairs(source_id) do
        for _idx, row in ipairs(mergedDailyRowsOne(id, start_ts, end_ts)) do
            local cur = by_day[row.ymd] or { ymd = row.ymd, seconds = 0, pages = 0 }
            cur.seconds = cur.seconds + row.seconds
            cur.pages = cur.pages + row.pages
            by_day[row.ymd] = cur
        end
    end
    local rows = {}
    for _ymd, row in pairs(by_day) do
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b) return a.ymd < b.ymd end)
    return rows
end

--- 追加一条阅读统计。
---@param row BookStatsRow
---@param status integer|nil sync_status，缺省 PENDING
---@return boolean
function StatsDB.add(row, status)
    local source_id = row.source_id
    local start_time = tonumber(row.start_time)
    local duration = tonumber(row.duration)
    if not start_time or not duration or duration <= 0 then
        return false
    end
    local event_count
    if row.record_type == SESSION_RECORD then
        -- 云端会话的 event_count 是源算好的页数（漫画 = 本次新推进的页数，其他格式 = pagesRead），
        -- **0 是合法值**（打开没翻页 / 重读同一段）。夹到 1 会让每天的页数凭空多一页。
        event_count = math.max(0, tonumber(row.event_count) or 0)
    else
        -- 本地逐页 / 压缩行缺字段时按一页算，沿用旧口径。
        event_count = math.max(1, tonumber(row.event_count) or 1)
    end
    return DB.exec(
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
        status or StatsDB.PENDING,
        event_count,
        tonumber(row.last_time) or 0
    ) ~= nil
end

--- 列出指定源的待上传统计。
---@param source_id string
---@param limit number|nil
---@return table[]
function StatsDB.unsyncedBySource(source_id, limit)
    local result, nrows = DB.query(
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
    return DB.rowexec(
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

--- 一本书本地采集记录覆盖的时间段 [起, 止)；page_rollup 只知道所在小时，按整小时算。
---@param source_id string
---@param stable_id string
---@return { [1]: integer, [2]: integer }[]
function StatsDB.localSpans(source_id, stable_id)
    local result, nrows = DB.query(
        [[SELECT start_time, CASE WHEN record_type='page_rollup' THEN 3600 ELSE duration END
          FROM reading_stats WHERE source_id=? AND stable_id=? AND record_type IN ('page','page_rollup');]],
        source_id, stable_id
    )
    local spans = {}
    for i = 1, nrows do
        local start = tonumber(result[1][i]) or 0
        spans[i] = { start, start + (tonumber(result[2][i]) or 0) }
    end
    return spans
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
    for _idx, row in ipairs(rows) do
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
            return DB.exec(
                "DELETE FROM reading_stats WHERE source_id=? AND sync_status=1;",
                source_id
            ) ~= nil
        end
        if replace and replace.mode == "synced_books" then
            for _idx, stable_id in ipairs(replace.stable_ids or {}) do
                if not DB.exec(
                    [[DELETE FROM reading_stats WHERE source_id=? AND stable_id=? AND sync_status=1
                        AND record_type IN ('page','page_rollup');]],
                    source_id, stable_id
                ) then return false end
            end
            return true
        end
        if replace and type(replace.ranges) == "table" then
            for _idx, range in ipairs(replace.ranges) do
                if not deleteSyntheticInRange(
                    source_id, range.from_ts, range.to_ts, range.stable_prefix
                ) then return false end
            end
            return true
        end
        if not (replace and from and to) then return true end
        return deleteSyntheticInRange(source_id, from, to)
    end

    local result = DB.transaction(function()
        -- 单书明细按 stable_id 精确整本替换：不走前缀，书 id 可能互为前缀
        for _idx, stable_id in ipairs(replace and replace.books or {}) do
            if not DB.exec(
                [[DELETE FROM reading_stats WHERE source_id=? AND stable_id=?
                    AND record_type IN ('book_day','book_total','cloud_session');]],
                source_id, stable_id
            ) then
                return nil
            end
        end
        if not clearRange() then return nil end
        local counts = { imported = 0, skipped = 0 }
        for _idx, row in ipairs(rows) do
            local duplicate = StatsDB.exists(row)
            if not StatsDB.add(row, StatsDB.SYNCED) then return nil end
            if duplicate then
                counts.skipped = counts.skipped + 1
            else
                counts.imported = counts.imported + 1
            end
        end
        return counts
    end)
    if not result then logger.warn("book.db replaceSynced failed", source_id) end
    return result
end

--- 汇总某源阅读统计：总时长/页数、近 7 天时长、最长单日。
--- source_id 可为单源字符串，或已启用源 id 列表（混合模式）。
---@param source_id string|string[]
---@return { total_seconds: number, total_pages: number, last7_seconds: number, longest_day_seconds: number }
function StatsDB.summaryBySource(source_id)
    local daily = mergedDailyRows(source_id)
    local total_seconds, total_pages, last7_seconds, longest_day_seconds, extra = 0, 0, 0, 0, 0
    local cutoff = os.date("%Y-%m-%d", os.time() - 6 * 86400)
    for _idx, row in ipairs(daily) do
        local seconds = tonumber(row.seconds) or 0
        total_seconds = total_seconds + seconds
        extra = extra + (row.extra or 0)
        total_pages = total_pages + (tonumber(row.pages) or 0)
        if row.ymd >= cutoff then
            last7_seconds = last7_seconds + seconds
        end
        if seconds > longest_day_seconds then
            longest_day_seconds = seconds
        end
    end
    -- 权威 total 是单源语义（微信）；混合跨源只用合并日桶。
    -- 快照不含拉取之后本地新读的，和日桶同一口径补上，否则不重新拉取总时长就不动。
    if type(source_id) == "string" then
        local remote_total, fetched_at = DB.rowexec(
            [[SELECT duration, last_time FROM reading_stats
              WHERE source_id=? AND record_type='total' ORDER BY duration DESC LIMIT 1;]],
            source_id
        )
        if (tonumber(remote_total) or 0) > 0 then
            fetched_at = tonumber(fetched_at) or 0
            total_seconds = tonumber(remote_total) + extra + (tonumber(DB.rowexec(
                [[SELECT COALESCE(SUM(duration),0) FROM reading_stats
                  WHERE source_id=? AND record_type IN ('page','page_rollup') AND ]] .. FRESH_LOCAL .. ";",
                source_id, fetched_at, fetched_at
            )) or 0)
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
--- 有云端单书快照（book_total）时，总时长 = 快照 + 快照后读的 + 仍未上传的本地时长；
--- 快照前已上传的本地时长已含在快照里，不能再加。没有快照时就是本地累计。
--- 页数 = 云端会话的 event_count + 未被会话覆盖的本地页（见下方注释）。
---@param source_id string
---@param stable_id string
---@return { total_seconds: number, local_seconds: number, total_pages: number, pages: number, last_read: number, first_read: number }
function StatsDB.summaryByBook(source_id, stable_id)
    local snapshot, fetched_at = DB.rowexec(
        [[SELECT duration, start_time FROM reading_stats
          WHERE source_id=? AND stable_id=? AND record_type='book_total' LIMIT 1;]],
        source_id,
        stable_id
    )
    -- 页数不能只看本地：漫画的页数在云端会话上（cloud_session.event_count = 本次新推进页数，
    -- 源侧已按「最远读到第几页」折算，重读不重复计）。
    -- 但本地页行上报成功后已经包含在当天那条会话里，直接相加会双计 —— 所以只对
    -- 「当天真有云端会话」的本地页做去重（covered），其余本地页照常计入。
    -- 这条覆盖判定不能省成「有会话就整本去重」：其他来源（微信 / moon / WebDAV）只回逐页行、
    -- 根本没有会话行，一刀切套 FRESH_LOCAL 会让它们已同步的历史页数凭空归零。
    local local_seconds, fresh_seconds, pages, total_pages = DB.rowexec(
        [[WITH f(at) AS (SELECT ?),
                 covered(day) AS (
                   SELECT DISTINCT date(start_time,'unixepoch','localtime')
                   FROM reading_stats
                   WHERE source_id=? AND stable_id=? AND record_type='cloud_session')
          SELECT COALESCE(SUM(CASE WHEN record_type IN ('page','page_rollup')
                                   THEN duration ELSE 0 END),0),
                 COALESCE(SUM(CASE WHEN record_type IN ('page','page_rollup')
                                    AND ]] .. FRESH_LOCAL_AT .. [[
                                   THEN duration ELSE 0 END),0),
                 COALESCE(SUM(CASE WHEN record_type='cloud_session' THEN event_count
                                   WHEN record_type IN ('page','page_rollup')
                                        AND (]] .. FRESH_LOCAL_AT .. [[
                                             OR date(start_time,'unixepoch','localtime')
                                                NOT IN (SELECT day FROM covered))
                                   THEN event_count ELSE 0 END),0),
                 COALESCE(MAX(total_pages),0)
          FROM reading_stats, f
          WHERE source_id=? AND stable_id=?
            AND record_type IN ('page','page_rollup','cloud_session');]],
        tonumber(fetched_at) or 0,
        source_id,
        stable_id,
        source_id,
        stable_id
    )
    -- 上次阅读时间：本机逐页 + 云端单书日 / 会话都算。只有云端时长的书（例如交给 kamare
    -- 打开、Moon 自己没记逐页记录）不能因为 pages=0 就显示成 1970 / 暂无阅读记录。
    local last_read = DB.rowexec(
        [[SELECT COALESCE(MAX(CASE WHEN record_type='page_rollup'
                    THEN last_time ELSE start_time END),0)
          FROM reading_stats WHERE source_id=? AND stable_id=?
            AND record_type IN ('page','page_rollup','book_day','cloud_session');]],
        source_id,
        stable_id
    )
    local total_seconds = tonumber(local_seconds) or 0
    if snapshot then
        total_seconds = tonumber(snapshot) + (tonumber(fresh_seconds) or 0)
    end
    local first_read = DB.rowexec(
        [[SELECT COALESCE(MIN(start_time),0) FROM reading_stats WHERE source_id=? AND stable_id=?
            AND record_type IN ('page','page_rollup','book_day','cloud_session');]],
        source_id,
        stable_id
    )
    return {
        total_seconds = total_seconds,
        local_seconds = tonumber(local_seconds) or 0,
        total_pages = tonumber(total_pages) or 0,
        pages = tonumber(pages) or 0,
        last_read = tonumber(last_read) or 0,
        first_read = tonumber(first_read) or 0,
    }
end

--- 单源：云端时段桶 + 本机逐页记录按（本地日期，小时）合并，口径与按天一致
--- （有云端桶的小时 = 云端 + 拉取后本机新读的；merge_local_stats 打开时再与本机该小时取较大值；
--- 没有云端桶的小时只有本机）。page_rollup 的 start_time 是整点，压缩后仍落在原小时。
---@param source_id string
---@return table<string, number[]> ymd → 24 格秒数（[1] 为 0 点）
local function hourlyRowsOne(source_id)
    local fetched_at = tonumber(DB.rowexec(
        "SELECT MAX(last_time) FROM reading_stats WHERE source_id=? AND record_type='hour';",
        source_id
    )) or 0
    local result, nrows = DB.query(
        [[SELECT strftime('%Y-%m-%d', start_time,'unixepoch','localtime') AS day,
                 CAST(strftime('%H', start_time,'unixepoch','localtime') AS INTEGER) AS hour,
                 record_type,
                 COALESCE(SUM(duration),0),
                 COALESCE(SUM(CASE WHEN ]] .. FRESH_LOCAL .. [[ THEN duration ELSE 0 END),0)
          FROM reading_stats WHERE source_id=? AND record_type IN ('hour','page','page_rollup')
          GROUP BY day, hour, record_type;]],
        fetched_at, fetched_at, source_id
    )
    local cloud, local_hours, fresh, slots = {}, {}, {}, {}
    for i = 1, nrows do
        local key = result[1][i] .. "#" .. tostring(result[2][i])
        slots[key] = { ymd = result[1][i], hour = (tonumber(result[2][i]) or 0) + 1 }
        if result[3][i] == HOUR_RECORD then
            cloud[key] = tonumber(result[4][i]) or 0
        else
            local_hours[key] = (local_hours[key] or 0) + (tonumber(result[4][i]) or 0)
            fresh[key] = (fresh[key] or 0) + (tonumber(result[5][i]) or 0)
        end
    end
    local merge = require("utils.settings").getSource(source_id).merge_local_stats == true
    local out = {}
    for key, slot in pairs(slots) do
        local local_seconds = local_hours[key] or 0
        local seconds
        if cloud[key] then
            seconds = cloud[key] + (fresh[key] or 0)
            if merge then seconds = math.max(seconds, local_seconds) end
        else
            seconds = local_seconds
        end
        if seconds > 0 then
            local hours = out[slot.ymd]
            if not hours then
                hours = {}
                for h = 1, 24 do hours[h] = 0 end
                out[slot.ymd] = hours
            end
            hours[slot.hour] = hours[slot.hour] + seconds
        end
    end
    return out
end

--- 按（本地日期，小时）汇总的阅读秒数；多源先单源合并再逐格相加。
---@param source_id string|string[]
---@return table<string, number[]> ymd → 24 格秒数（[1] 为 0 点）
function StatsDB.hourlyBySource(source_id)
    if type(source_id) ~= "table" then
        return hourlyRowsOne(source_id)
    end
    local out = {}
    for _idx, id in ipairs(source_id) do
        for ymd, hours in pairs(hourlyRowsOne(id)) do
            local target = out[ymd]
            if not target then
                target = {}
                for h = 1, 24 do target[h] = 0 end
                out[ymd] = target
            end
            for h = 1, 24 do target[h] = target[h] + hours[h] end
        end
    end
    return out
end

--- 云端单书累计快照：stable_id → 秒（判断哪些书需要重拉按日明细）。
---@param source_id string
---@return table<string, number>
function StatsDB.bookTotals(source_id)
    local result, nrows = DB.query(
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
--- 页数两侧合并：云端会话（cloud_session.event_count）按天计入，只叠 fresh 的本地页 ——
--- 本地页上报后已含在当天的会话里。那天没有会话时本地页照旧全量计入（其他来源没有会话行）。
---@param source_id string|string[]
---@param filter string 追加到 WHERE 的片段，列名用 ``r.`` 前缀；作用于云端与本地两侧
---@param filter_args any[]
---@return string sql 以 WITH 开头，调用方接 SELECT … FROM bd
---@return any[] args
local function bookDays(source_id, filter, filter_args)
    local src, src_args = DB.sourceClause("r.source_id", source_id)
    local args = {}
    for _idx, list in ipairs({ src_args, filter_args, src_args, src_args, filter_args, src_args, filter_args }) do
        for _idx, v in ipairs(list) do args[#args + 1] = v end
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
                 SUM(r.event_count) AS pages,
                 SUM(CASE WHEN r.sync_status=0 OR r.start_time>=f.at THEN r.event_count ELSE 0 END)
                   AS fresh_pages,
                 MAX(r.page) AS max_page,
                 MAX(r.total_pages) AS max_total_pages
          FROM reading_stats r LEFT JOIN fetched f
            ON f.source_id=r.source_id AND f.stable_id=r.stable_id
          WHERE ]] .. src .. [[ AND r.record_type IN ('page','page_rollup')]] .. filter .. [[
          GROUP BY 1, 2, 3),
        cloud_pages AS (
          SELECT r.source_id, r.stable_id, date(r.start_time,'unixepoch','localtime') AS day,
                 SUM(r.event_count) AS pages
          FROM reading_stats r
          WHERE ]] .. src .. [[ AND r.record_type='cloud_session']] .. filter .. [[
          GROUP BY 1, 2, 3),
        bd AS (
          SELECT l.source_id, l.stable_id, l.day,
                 CASE WHEN c.seconds IS NULL THEN l.seconds ELSE c.seconds + l.fresh END AS seconds,
                 CASE WHEN cp.pages IS NULL THEN l.pages ELSE l.fresh_pages + cp.pages END AS pages,
                 l.max_page, l.max_total_pages
          FROM loc l LEFT JOIN cloud c
            ON c.source_id=l.source_id AND c.stable_id=l.stable_id AND c.day=l.day
            LEFT JOIN cloud_pages cp
            ON cp.source_id=l.source_id AND cp.stable_id=l.stable_id AND cp.day=l.day
          UNION ALL
          SELECT c.source_id, c.stable_id, c.day, c.seconds, COALESCE(cp.pages,0), 0, 0
          FROM cloud c LEFT JOIN loc l
            ON l.source_id=c.source_id AND l.stable_id=c.stable_id AND l.day=c.day
            LEFT JOIN cloud_pages cp
            ON cp.source_id=c.source_id AND cp.stable_id=c.stable_id AND cp.day=c.day
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
    local result, nrows = DB.query(
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

--- 多卷书：把各卷身份的统计合成一本（系列容器详情页用）。
--- 各身份的行互不重叠（多卷系列的进度 / 统计都记在卷行上），直接相加不会重复。
---@param source_id string
---@param stable_ids string|string[]
---@return { total_seconds: number, local_seconds: number, total_pages: number, pages: number, last_read: number, first_read: number }
function StatsDB.summaryByBooks(source_id, stable_ids)
    if type(stable_ids) ~= "table" then return StatsDB.summaryByBook(source_id, stable_ids) end
    local out = {
        total_seconds = 0, local_seconds = 0, total_pages = 0, pages = 0, last_read = 0, first_read = 0,
    }
    for _idx, stable_id in ipairs(stable_ids) do
        local one = StatsDB.summaryByBook(source_id, stable_id)
        out.total_seconds = out.total_seconds + one.total_seconds
        out.local_seconds = out.local_seconds + one.local_seconds
        out.total_pages = out.total_pages + one.total_pages
        out.pages = out.pages + one.pages
        out.last_read = math.max(out.last_read, one.last_read)
        if one.first_read > 0 then
            out.first_read = out.first_read == 0 and one.first_read or math.min(out.first_read, one.first_read)
        end
    end
    return out
end

--- 多卷书按天聚合（各卷同一天相加）；参数与 dailyByBook 同。
---@param source_id string
---@param stable_ids string|string[]
---@param limit number|nil
---@return table[] rows { ymd, seconds, pages }（日期倒序）
function StatsDB.dailyByBooks(source_id, stable_ids, limit)
    if type(stable_ids) ~= "table" then return StatsDB.dailyByBook(source_id, stable_ids, limit) end
    if #stable_ids == 0 then return {} end
    local marks, filter_args = {}, {}
    for _idx, stable_id in ipairs(stable_ids) do
        marks[#marks + 1] = "?"
        filter_args[#filter_args + 1] = stable_id
    end
    local cte, args = bookDays(source_id,
        " AND r.stable_id IN (" .. table.concat(marks, ",") .. ")", filter_args)
    args[#args + 1] = math.max(1, tonumber(limit) or 5)
    local result, nrows = DB.query(
        cte .. [[SELECT day, COALESCE(SUM(seconds),0), COALESCE(SUM(pages),0)
          FROM bd GROUP BY day ORDER BY day DESC LIMIT ?;]],
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

--- 单本书 / 多卷书的阅读会话（云端会话行）：详情页「阅读记录」列真实起止时段。
--- 本机有逐页记录的天不列云端会话，避免同一次阅读在列表里出现两遍。
---@param source_id string
---@param stable_ids string|string[]
---@param limit number|nil 最多返回条数，默认 10
---@return table[] rows { start_time: number, duration: number, pages: number, stable_id: string }（开始时间倒序）
function StatsDB.sessionsByBook(source_id, stable_ids, limit)
    local ids = type(stable_ids) == "table" and stable_ids or { stable_ids }
    if #ids == 0 then return {} end
    ---@type string[], any[]
    local marks, args = {}, { source_id }
    for _idx, stable_id in ipairs(ids) do
        marks[#marks + 1] = "?"
        args[#args + 1] = stable_id
    end
    args[#args + 1] = math.max(1, tonumber(limit) or 10)
    local result, nrows = DB.query(
        [[SELECT r.stable_id, r.start_time, r.duration, r.event_count
          FROM reading_stats r
          WHERE r.source_id=? AND r.stable_id IN (]] .. table.concat(marks, ",") .. [[)
            AND r.record_type='cloud_session'
            AND NOT EXISTS (
              SELECT 1 FROM reading_stats l
               WHERE l.source_id=r.source_id AND l.stable_id=r.stable_id
                 AND l.record_type IN ('page','page_rollup')
                 AND date(l.start_time,'unixepoch','localtime')
                     = date(r.start_time,'unixepoch','localtime'))
          ORDER BY r.start_time DESC LIMIT ?;]],
        unpack(args)
    )
    local rows = {}
    for i = 1, nrows do
        rows[#rows + 1] = {
            stable_id = result[1][i],
            start_time = tonumber(result[2][i]) or 0,
            duration = tonumber(result[3][i]) or 0,
            pages = tonumber(result[4][i]) or 0,
        }
    end
    return rows
end

--- 按天聚合某源阅读统计（本地洞察日历、首页热力图用）。
---@param source_id string|string[]
---@param start_ts number|nil 与 end_ts 同给时只聚合 [start_ts, end_ts)，走 (source_id, start_time) 索引
---@param end_ts number|nil
---@return table[] rows { ymd, seconds, pages }（按日期升序）
function StatsDB.dailyBySource(source_id, start_ts, end_ts)
    return mergedDailyRows(source_id, start_ts, end_ts)
end

--- 按天按书聚合某源阅读统计（本地洞察当日书单用），含云端单书按日时长。
--- 进度近似 = 当日读到最深页 / 当时总页数；只有云端时长的那天没有页坐标，两者为 0。
---@param source_id string|string[]
---@return table[] rows { ymd, source_id, stable_id, seconds, max_page, max_total_pages }（日期升序、时长降序）
function StatsDB.dailyBooksBySource(source_id)
    local cte, args = bookDays(source_id, "", {})
    local result, nrows = DB.query(
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
    -- 书数按（书，天）合并口径（含其他设备读过的书），页数按同一口径（云端会话 + 未被会话覆盖的本地页）；
    -- 总时长按天走账户日桶合并口径，与洞察日历保持一致。
    local cte, args = bookDays(source_id, " AND r.start_time>=? AND r.start_time<?",
        { tonumber(start_ts) or 0, tonumber(end_ts) or 0 })
    local books, pages = DB.rowexec(
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
    local result, nrows = DB.query(
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

--- 本机逐页 / 压缩记录，按开始时间升序（洞察里切分阅读段、算速度用）。云端日桶没有逐页坐标，不在内。
---@param source_id string|string[]
---@param from_ts number 起（含）
---@return table[] rows { source_id, stable_id, start_time, duration, pages }
function StatsDB.sessionRows(source_id, from_ts)
    local src, args = DB.sourceClause("r.source_id", source_id)
    args[#args + 1] = tonumber(from_ts) or 0
    local result, nrows = DB.query(
        [[SELECT r.source_id, r.stable_id, r.start_time, r.duration, r.event_count
          FROM reading_stats r
          WHERE ]] .. src .. [[ AND r.start_time>=?
            AND (r.record_type IN ('page','page_rollup')
              -- 云端会话只补本机没有逐页记录的书 / 天，别和本机会话重复列一次。
              OR (r.record_type='cloud_session' AND NOT EXISTS (
                    SELECT 1 FROM reading_stats l
                     WHERE l.source_id=r.source_id AND l.stable_id=r.stable_id
                       AND l.record_type IN ('page','page_rollup')
                       AND date(l.start_time,'unixepoch','localtime')
                           = date(r.start_time,'unixepoch','localtime'))))
          ORDER BY r.start_time, r.id;]],
        unpack(args)
    )
    local rows = {}
    for i = 1, nrows do
        rows[i] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            start_time = tonumber(result[3][i]) or 0,
            duration = tonumber(result[4][i]) or 0,
            pages = tonumber(result[5][i]) or 0,
        }
    end
    return rows
end

--- 读完（finished=true）或在读的书，附带最后阅读时间和本机累计时长。
--- 读完 = 手动已读，或未被标未读且进度 ≥ 99%；在读 = 有进度但没读完。
--- 最后阅读时间取本机记录，没有就退回进度更新时间。
---@param source_id string|string[]
---@param finished boolean
---@param limit number|nil 仅在读时有效，按最近阅读取前 N 本
---@return table[] rows { source_id, stable_id, title, authors, category, fraction, last_time, seconds }
function StatsDB.progressBooks(source_id, finished, limit)
    local src, args = DB.sourceClause("b.source_id", source_id)
    local cond = finished
        and "(b.read_state=1 OR (b.read_state=0 AND COALESCE(p.fraction,0)>=0.99))"
        or "(b.read_state=0 AND COALESCE(p.fraction,0)>0 AND p.fraction<0.99)"
    local tail = ""
    if not finished then
        tail = " ORDER BY 7 DESC LIMIT ?"
        args[#args + 1] = math.max(1, tonumber(limit) or 5)
    end
    local result, nrows = DB.query(
        [[SELECT b.source_id, b.stable_id, b.title, b.authors, b.category,
                 COALESCE(p.fraction, 0),
                 COALESCE((SELECT MAX(r.start_time) FROM reading_stats r
                           WHERE r.source_id=b.source_id AND r.stable_id=b.stable_id
                             AND r.record_type IN ('page','page_rollup')), p.updated_at, 0),
                 COALESCE((SELECT SUM(r.duration) FROM reading_stats r
                           WHERE r.source_id=b.source_id AND r.stable_id=b.stable_id
                             AND r.record_type IN ('page','page_rollup')), 0)
          FROM books b LEFT JOIN pending_progress p
            ON p.source_id=b.source_id AND p.stable_id=b.stable_id
          WHERE ]] .. src .. " AND b.deleted=0 AND b.hidden=0 AND " .. cond .. tail .. ";",
        unpack(args)
    )
    local rows = {}
    for i = 1, nrows do
        rows[i] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            title = result[3][i],
            authors = result[4][i],
            category = result[5][i],
            fraction = tonumber(result[6][i]) or 0,
            last_time = tonumber(result[7][i]) or 0,
            seconds = tonumber(result[8][i]) or 0,
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
    local result, nrows = DB.query(
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

    return DB.transaction(function()
        for _idx, group in ipairs(order) do
            if not DB.exec(
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
                return nil
            end
        end
        return execByIds("DELETE FROM reading_stats", ids) and #ids or nil
    end)
end

--- 标记已被 Source 确认的记录。
---@param ids number[]
---@return boolean
function StatsDB.markSynced(ids)
    if #ids == 0 then
        return false
    end
    return DB.transaction(function()
        return execByIds("UPDATE reading_stats SET sync_status=1", ids)
    end) == true
end

return StatsDB
