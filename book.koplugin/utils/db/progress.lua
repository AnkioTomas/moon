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
    return Base.exec(
        [[INSERT INTO pending_progress
            (source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at)
          VALUES (?,?,?,?,?,?,?)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            fraction=excluded.fraction,
            chapter_idx=excluded.chapter_idx,
            chapter_fraction=excluded.chapter_fraction,
            locator=excluded.locator,
            updated_at=excluded.updated_at;]],
        source_id,
        stable_id,
        frac,
        pos.chapter_idx,
        pos.chapter_fraction,
        pos.locator,
        os.time()
    ) ~= nil
end

--- 按 (source_id, stable_id) 取单条待上传进度（本地进度判读用）
---@param source_id string
---@param stable_id string
---@return table|nil { fraction, chapter_idx, chapter_fraction, locator, updated_at }
function ProgressDB.get(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    Base.ensure()
    local fraction, chapter_idx, chapter_fraction, locator, updated_at = Base.rowexec(
        [[SELECT fraction, chapter_idx, chapter_fraction, locator, updated_at
          FROM pending_progress WHERE source_id=? AND stable_id=? LIMIT 1;]],
        source_id,
        stable_id
    )
    if fraction == nil then
        return nil
    end
    return {
        fraction = tonumber(fraction) or 0,
        chapter_idx = chapter_idx ~= nil and tonumber(chapter_idx) or nil,
        chapter_fraction = chapter_fraction ~= nil and tonumber(chapter_fraction) or nil,
        locator = locator,
        updated_at = tonumber(updated_at) or 0,
    }
end

--- 列出待上传进度（可按 source_id 过滤）
---@param source_id string|nil
---@return table[]
function ProgressDB.all(source_id)    Base.ensure()
    local sql
    if type(source_id) == "string" and source_id ~= "" then
        sql = [[SELECT source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at
                 FROM pending_progress WHERE source_id=? ORDER BY updated_at ASC;]]
    else
        sql = [[SELECT source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at
                FROM pending_progress ORDER BY updated_at ASC;]]
    end
    local result, nrows
    if type(source_id) == "string" and source_id ~= "" then
        result, nrows = Base.query(sql, source_id)
    else
        result, nrows = Base.query(sql)
    end
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
    return Base.exec(
        [[DELETE FROM pending_progress WHERE source_id=? AND stable_id=?;]],
        source_id,
        stable_id
    ) ~= nil
end

return ProgressDB
