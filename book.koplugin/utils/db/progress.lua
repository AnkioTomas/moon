--[[--
pending_progress 表：待上传进度（一书一条）

@module koplugin.book.utils.db.progress
--]]

local Base = require("utils.db.base")

local ProgressDB = {}

--- 插入或更新待上传进度
---@param source_id string
---@param stable_id string
---@param pos ProgressPosition
---@return boolean
function ProgressDB.upsert(source_id, stable_id, pos)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" or type(pos) ~= "table" then
        return false
    end
    local frac = tonumber(pos.fraction)
    if not frac then
        return false
    end
    Base.ensure()
    local sql = string.format(
        [[INSERT INTO pending_progress
            (source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at)
          VALUES (%s,%s,%s,%s,%s,%s,%s)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            fraction=excluded.fraction,
            chapter_idx=excluded.chapter_idx,
            chapter_fraction=excluded.chapter_fraction,
            locator=excluded.locator,
            updated_at=excluded.updated_at;]],
        Base.sqlQuote(source_id),
        Base.sqlQuote(stable_id),
        Base.sqlQuote(frac),
        Base.sqlQuote(pos.chapter_idx),
        Base.sqlQuote(pos.chapter_fraction),
        Base.sqlQuote(pos.locator),
        Base.sqlQuote(os.time())
    )
    return Base.exec(sql) ~= nil
end

--- 列出待上传进度（可按 source_id 过滤）
---@param source_id string|nil
---@return table[]
function ProgressDB.all(source_id)
    Base.ensure()
    local sql
    if type(source_id) == "string" and source_id ~= "" then
        sql = string.format(
            [[SELECT source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at
              FROM pending_progress WHERE source_id=%s ORDER BY updated_at ASC;]],
            Base.sqlQuote(source_id)
        )
    else
        sql = [[SELECT source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at
                FROM pending_progress ORDER BY updated_at ASC;]]
    end
    local result, nrows = Base.query(sql)
    local out = {}
    if result and nrows and nrows > 0 then
        for i = 1, nrows do
            out[#out + 1] = {
                source_id = result[1][i],
                stable_id = result[2][i],
                fraction = tonumber(result[3][i]) or 0,
                chapter_idx = result[4][i] ~= nil and tonumber(result[4][i]) or nil,
                chapter_fraction = result[5][i] ~= nil and tonumber(result[5][i]) or nil,
                locator = result[6][i],
                updated_at = tonumber(result[7][i]) or 0,
            }
        end
    end
    return out
end

--- 删除一条待上传进度
---@param source_id string
---@param stable_id string
---@return boolean
function ProgressDB.delete(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return false
    end
    Base.ensure()
    return Base.exec(string.format(
        [[DELETE FROM pending_progress WHERE source_id=%s AND stable_id=%s;]],
        Base.sqlQuote(source_id),
        Base.sqlQuote(stable_id)
    )) ~= nil
end

return ProgressDB
