--[[--
notes 表：每本书或章节的 KOReader 注解完整快照。

sync_status=0 表示待上传，1 表示已同步。

chapter_idx = 0 表示整本文件；正数表示章节文件。

@module koplugin.book.utils.db.note
--]]

local Base = require("utils.db.base")

local NoteDB = {}

--- 覆盖指定书籍或章节的注解快照。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@param payload string JSON 编码后的 KOReader annotations
---@param updated_at number|nil
---@param synced boolean|nil 此快照已由远端确认
---@return boolean
function NoteDB.upsert(source_id, stable_id, chapter_idx, payload, updated_at, synced)
    source_id = Base.requireSourceId(source_id)
    chapter_idx = tonumber(chapter_idx) or 0
    if not source_id or type(stable_id) ~= "string" or stable_id == ""
        or chapter_idx < 0 or chapter_idx % 1 ~= 0
        or type(payload) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[INSERT INTO notes (source_id, stable_id, chapter_idx, payload, updated_at, sync_status)
          VALUES (?,?,?,?,?,?)
          ON CONFLICT(source_id, stable_id, chapter_idx) DO UPDATE SET
            payload=excluded.payload,
            updated_at=excluded.updated_at,
            sync_status=excluded.sync_status;]],
        source_id,
        stable_id,
        chapter_idx,
        payload,
        tonumber(updated_at) or os.time(),
        synced and 1 or 0
    ) ~= nil
end

--- 保存远端注解快照；本地待上传快照不允许被覆盖。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@param payload string
---@param updated_at number|nil
---@return boolean
function NoteDB.upsertRemote(source_id, stable_id, chapter_idx, payload, updated_at)
    source_id = Base.requireSourceId(source_id)
    chapter_idx = tonumber(chapter_idx) or 0
    if not source_id or type(stable_id) ~= "string" or stable_id == ""
        or chapter_idx < 0 or chapter_idx % 1 ~= 0 or type(payload) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[INSERT INTO notes (source_id, stable_id, chapter_idx, payload, updated_at, sync_status)
          VALUES (?,?,?,?,?,1)
          ON CONFLICT(source_id, stable_id, chapter_idx) DO UPDATE SET
            payload=excluded.payload, updated_at=excluded.updated_at, sync_status=1
          WHERE notes.sync_status=1;]],
        source_id, stable_id, chapter_idx, payload, tonumber(updated_at) or os.time()
    ) ~= nil
end

local COLUMNS = "source_id, stable_id, chapter_idx, payload, updated_at, sync_status"

---@param result table|nil
---@param nrows integer|nil
---@return table[]
local function rows(result, nrows)
    local out = {}
    if not result or not nrows or nrows <= 0 then
        return out
    end
    for i = 1, nrows do
        out[#out + 1] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            chapter_idx = tonumber(result[3][i]) or 0,
            payload = result[4][i],
            updated_at = tonumber(result[5][i]) or 0,
            sync_status = tonumber(result[6][i]) or 0,
        }
    end
    return out
end

--- 按身份读取本地注解快照。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@return table|nil
function NoteDB.get(source_id, stable_id, chapter_idx)
    source_id = Base.requireSourceId(source_id)
    chapter_idx = tonumber(chapter_idx) or 0
    if not source_id or type(stable_id) ~= "string" or stable_id == ""
        or chapter_idx < 0 or chapter_idx % 1 ~= 0 then
        return nil
    end
    Base.ensure()
    local source, stable, chapter, payload, updated_at, sync_status = Base.rowexec(
        "SELECT " .. COLUMNS .. " FROM notes WHERE source_id=? AND stable_id=? AND chapter_idx=? LIMIT 1;",
        source_id,
        stable_id,
        chapter_idx
    )
    if not source then
        return nil
    end
    return {
        source_id = source,
        stable_id = stable,
        chapter_idx = tonumber(chapter) or 0,
        payload = payload,
        updated_at = tonumber(updated_at) or 0,
        sync_status = tonumber(sync_status) or 0,
    }
end

--- 列出指定源的本地注解快照。
---@param source_id string|nil
---@return table[]
function NoteDB.all(source_id)
    Base.ensure()
    local sql = "SELECT " .. COLUMNS .. " FROM notes"
    if type(source_id) == "string" and source_id ~= "" then
        return rows(Base.query(sql .. " WHERE source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(Base.query(sql .. " ORDER BY updated_at ASC;"))
end

--- 列出未同步的本地注解快照。
---@param source_id string|nil
---@return table[]
function NoteDB.unsynced(source_id)
    Base.ensure()
    local sql = "SELECT " .. COLUMNS .. " FROM notes WHERE sync_status=0"
    if type(source_id) == "string" and source_id ~= "" then
        return rows(Base.query(sql .. " AND source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(Base.query(sql .. " ORDER BY updated_at ASC;"))
end

--- 服务端确认后标记对应本地版本已同步。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@param updated_at number
---@return boolean
function NoteDB.markSynced(source_id, stable_id, chapter_idx, updated_at)
    source_id = Base.requireSourceId(source_id)
    chapter_idx = tonumber(chapter_idx) or 0
    updated_at = tonumber(updated_at)
    if not source_id or type(stable_id) ~= "string" or stable_id == ""
        or chapter_idx < 0 or chapter_idx % 1 ~= 0 or not updated_at then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[UPDATE notes SET sync_status=1
          WHERE source_id=? AND stable_id=? AND chapter_idx=? AND updated_at=?;]],
        source_id,
        stable_id,
        chapter_idx,
        updated_at
    ) ~= nil
end

return NoteDB
