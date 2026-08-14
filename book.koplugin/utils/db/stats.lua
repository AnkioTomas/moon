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
