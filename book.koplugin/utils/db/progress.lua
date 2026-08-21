--[[--
本地阅读进度（一书一条）。sync_status=0 表示待上传，1 表示已同步。

@module koplugin.book.utils.db.progress
--]]

local Base = require("utils.db.base")

local ProgressDB = {}

local COLUMNS = "source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at, sync_status"

---@param source_id string
---@param stable_id string
---@param pos ProgressPosition
---@return boolean
function ProgressDB.upsert(source_id, stable_id, pos)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" or type(pos) ~= "table" then
        return false
    end
    local fraction = tonumber(pos.fraction)
    if not fraction then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[INSERT INTO pending_progress
            (source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at, sync_status)
          VALUES (?,?,?,?,?,?,?,0)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            fraction=excluded.fraction,
            chapter_idx=excluded.chapter_idx,
            chapter_fraction=excluded.chapter_fraction,
            locator=excluded.locator,
            updated_at=excluded.updated_at,
            sync_status=0;]],
        source_id,
        stable_id,
        fraction,
        pos.chapter_idx,
        pos.chapter_fraction,
        pos.locator,
        tonumber(pos.updated_at) or os.time()
    ) ~= nil
end

--- 保存远端进度。未同步的本地版本不允许被远端覆盖。
---@param source_id string
---@param stable_id string
---@param pos ProgressPosition
---@return boolean
function ProgressDB.upsertRemote(source_id, stable_id, pos)
    source_id = Base.requireSourceId(source_id)
    local fraction = type(pos) == "table" and tonumber(pos.fraction) or nil
    if not source_id or type(stable_id) ~= "string" or stable_id == "" or not fraction then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[INSERT INTO pending_progress
            (source_id, stable_id, fraction, chapter_idx, chapter_fraction, locator, updated_at, sync_status)
          VALUES (?,?,?,?,?,?,?,1)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            fraction=excluded.fraction, chapter_idx=excluded.chapter_idx,
            chapter_fraction=excluded.chapter_fraction, locator=excluded.locator,
            updated_at=excluded.updated_at, sync_status=1
          WHERE pending_progress.sync_status=1;]],
        source_id, stable_id, fraction, pos.chapter_idx, pos.chapter_fraction,
        pos.locator, tonumber(pos.updated_at) or os.time()
    ) ~= nil
end

---@param source_id string
---@param stable_id string
---@return PendingProgress|nil
function ProgressDB.get(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    Base.ensure()
    local source, stable, fraction, chapter_idx, chapter_fraction, locator, updated_at, sync_status = Base.rowexec(
        "SELECT " .. COLUMNS .. " FROM pending_progress WHERE source_id=? AND stable_id=? LIMIT 1;",
        source_id,
        stable_id
    )
    if not source then
        return nil
    end
    return {
        source_id = source,
        stable_id = stable,
        fraction = tonumber(fraction) or 0,
        chapter_idx = chapter_idx ~= nil and tonumber(chapter_idx) or nil,
        chapter_fraction = chapter_fraction ~= nil and tonumber(chapter_fraction) or nil,
        locator = locator,
        updated_at = tonumber(updated_at) or 0,
        sync_status = tonumber(sync_status) or 0,
    }
end

---@param result table|nil
---@param nrows integer|nil
---@return PendingProgress[]
local function rows(result, nrows)
    local out = {}
    if not result or not nrows or nrows <= 0 then
        return out
    end
    for i = 1, nrows do
        out[#out + 1] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            fraction = tonumber(result[3][i]) or 0,
            chapter_idx = result[4][i] ~= nil and tonumber(result[4][i]) or nil,
            chapter_fraction = result[5][i] ~= nil and tonumber(result[5][i]) or nil,
            locator = result[6][i],
            updated_at = tonumber(result[7][i]) or 0,
            sync_status = tonumber(result[8] and result[8][i]) or 0,
        }
    end
    return out
end

---@param source_id string|nil
---@return PendingProgress[]
function ProgressDB.all(source_id)
    Base.ensure()
    local sql = "SELECT " .. COLUMNS .. " FROM pending_progress"
    if type(source_id) == "string" and source_id ~= "" then
        return rows(Base.query(sql .. " WHERE source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(Base.query(sql .. " ORDER BY updated_at ASC;"))
end

---@param source_id string|nil
---@return PendingProgress[]
function ProgressDB.unsynced(source_id)
    Base.ensure()
    local sql = "SELECT " .. COLUMNS .. " FROM pending_progress WHERE sync_status=0"
    if type(source_id) == "string" and source_id ~= "" then
        return rows(Base.query(sql .. " AND source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(Base.query(sql .. " ORDER BY updated_at ASC;"))
end

---@param source_id string
---@param stable_id string
---@param updated_at number
---@return boolean
function ProgressDB.markSynced(source_id, stable_id, updated_at)
    source_id = Base.requireSourceId(source_id)
    updated_at = tonumber(updated_at)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" or not updated_at then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[UPDATE pending_progress SET sync_status=1
          WHERE source_id=? AND stable_id=? AND updated_at=?;]],
        source_id,
        stable_id,
        updated_at
    ) ~= nil
end

return ProgressDB
