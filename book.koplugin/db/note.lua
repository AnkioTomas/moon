--[[--
notes 表：每本书或章节的 KOReader 注解完整快照。

sync_status=0 表示待上传，1 表示已同步。

chapter_idx = 0 表示整本文件；正数表示章节文件。

@module koplugin.book.db.note
--]]

local Base = require("db.base")

local NoteDB = {}

--- 创建 notes 表。
--- 仅在 Base.open() 的一次性 schema 初始化阶段调用。
---@return boolean 成功返回 true，SQL 失败返回 false
function NoteDB.ensureSchema()
    return Base.exec([[
CREATE TABLE IF NOT EXISTS notes (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL,
  chapter_idx INTEGER NOT NULL DEFAULT 0, payload TEXT NOT NULL,
  updated_at INTEGER NOT NULL, sync_status INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id, chapter_idx)
);
]]) ~= nil
end

--- 覆盖指定书籍或章节的注解快照。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@param payload string JSON 编码后的 KOReader annotations
---@param updated_at number|nil
---@param synced boolean|nil 此快照已由远端确认
---@return boolean
function NoteDB.upsert(source_id, stable_id, chapter_idx, payload, updated_at, synced)
    chapter_idx = tonumber(chapter_idx) or 0
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
    chapter_idx = tonumber(chapter_idx) or 0
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
    chapter_idx = tonumber(chapter_idx) or 0
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
    local sql = "SELECT " .. COLUMNS .. " FROM notes"
    if source_id ~= nil then
        return rows(Base.query(sql .. " WHERE source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(Base.query(sql .. " ORDER BY updated_at ASC;"))
end

--- 列出未同步的本地注解快照。
---@param source_id string|nil
---@return table[]
function NoteDB.unsynced(source_id)
    local sql = "SELECT " .. COLUMNS .. " FROM notes WHERE sync_status=0"
    if source_id ~= nil then
        return rows(Base.query(sql .. " AND source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(Base.query(sql .. " ORDER BY updated_at ASC;"))
end

--- 上传成功后落定这一版快照：写回 payload 并标记已同步，一条语句完成。
---
--- `updated_at` 参与 WHERE 是乐观锁，且**必须**和 payload 写入同一条语句：
--- 分成「先覆盖 payload、再 markSynced」两步时，第一步会用上传前的旧修订号把
--- 上传期间用户新划的线覆盖掉，第二步的乐观锁于是恰好匹配、脏标记也被清掉。
--- payload 允许为 nil（只标记不写内容）；修订号不变，因为内容语义上仍是这一版
--- （源侧只是回填了远端分配的 id）。
---
--- 返回值只表示 SQL 执行成功。是否真的命中那一行由调用方另行判断。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil nil 或 0 表示整本书那一份快照
---@param updated_at number 上传时快照的修订号，缺失则拒绝执行
---@param payload string|nil 源侧回填过 id 的快照
---@return boolean false 表示参数非法或 SQL 失败
function NoteDB.markSynced(source_id, stable_id, chapter_idx, updated_at, payload)
    chapter_idx = tonumber(chapter_idx) or 0
    updated_at = tonumber(updated_at)
    if payload ~= nil then
        return Base.exec(
            [[UPDATE notes SET sync_status=1, payload=?
              WHERE source_id=? AND stable_id=? AND chapter_idx=? AND updated_at=?;]],
            payload, source_id, stable_id, chapter_idx, updated_at
        ) ~= nil
    end
    return Base.exec(
        [[UPDATE notes SET sync_status=1
          WHERE source_id=? AND stable_id=? AND chapter_idx=? AND updated_at=?;]],
        source_id,
        stable_id,
        chapter_idx,
        updated_at
    ) ~= nil
end

--- 删除指定书籍或章节的注解快照。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@return boolean
function NoteDB.delete(source_id, stable_id, chapter_idx)
    chapter_idx = tonumber(chapter_idx) or 0
    return Base.exec(
        "DELETE FROM notes WHERE source_id=? AND stable_id=? AND chapter_idx=?;",
        source_id,
        stable_id,
        chapter_idx
    ) ~= nil
end

return NoteDB
