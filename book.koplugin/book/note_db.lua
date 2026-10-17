--[[--
notes 表：每本书或章节的 KOReader 注解完整快照。

sync_status=0 表示待上传，1 表示已同步。

chapter_idx = 0 表示整本文件；正数表示章节文件。

不变量：
  - upsertRemote 只覆盖已同步行，本地脏快照不被远端盖掉。
  - markSynced 必须把清脏与 payload 回填放在同一语句（WHERE 带 updated_at），
    否则会吃掉上传期间的新划线。
  - 合并 / 冲突策略在 book.note，本表只保证脏保护；完整 pull 仅开书。
书改名 / 收编时由 books_db 调 moveIdentity 迁身份。

@module koplugin.book.book.note_db
--]]

local DB = require("utils.db")
require("book.books_db")

local NoteDB = {}

DB.schema("notes", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS notes (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL,
  chapter_idx INTEGER NOT NULL DEFAULT 0, payload TEXT NOT NULL,
  updated_at INTEGER NOT NULL, sync_status INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id, chapter_idx)
);
]]) ~= nil
end)

--- 书改名 / 收编时由 books_db 调用。
--- 收编（merge）时旧身份的笔记还没推就比新身份的已同步副本新，先清掉新身份那份。
function NoteDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    return (not merge or DB.exec(
        [[DELETE FROM notes WHERE source_id=? AND stable_id=? AND EXISTS (
            SELECT 1 FROM notes WHERE source_id=? AND stable_id=? AND sync_status=0);]],
        source_id, new_stable_id, source_id, old_stable_id) ~= nil)
        and DB.moveIdentity("notes", source_id, old_stable_id, new_stable_id, merge)
end

--- 书被删（墓碑撕掉）时由 books_db 调用。
function NoteDB.removeIdentity(source_id, stable_id)
    return DB.removeIdentity("notes", source_id, stable_id)
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
    return DB.exec(
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
    return DB.exec(
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
    local source, stable, chapter, payload, updated_at, sync_status = DB.rowexec(
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

--- 章号重排（订阅目录刷新后文章换了位置）：map[旧章号] = 新章号，map 里没有的章（文章已淘汰）删掉。
--- 先挪到负号再翻正，避免新旧章号互相撞主键。
---@param source_id string
---@param stable_id string
---@param map table<integer, integer>
---@return boolean
function NoteDB.remapChapters(source_id, stable_id, map)
    return DB.transaction(function()
        for old, new in pairs(map) do
            if DB.exec("UPDATE notes SET chapter_idx=? WHERE source_id=? AND stable_id=? AND chapter_idx=?;",
                -new, source_id, stable_id, old) == nil then return false end
        end
        return DB.exec("DELETE FROM notes WHERE source_id=? AND stable_id=? AND chapter_idx>0;", source_id, stable_id) ~= nil
            and DB.exec("UPDATE notes SET chapter_idx=-chapter_idx WHERE source_id=? AND stable_id=? AND chapter_idx<0;",
                source_id, stable_id) ~= nil
    end)
end

--- 列出指定源（再给 stable_id 则只取这本书各章）的本地注解快照。
---@param source_id string|nil
---@param stable_id string|nil
---@return table[]
function NoteDB.all(source_id, stable_id)
    local sql = "SELECT " .. COLUMNS .. " FROM notes"
    if stable_id ~= nil then
        return rows(DB.query(sql .. " WHERE source_id=? AND stable_id=? ORDER BY updated_at ASC;",
            source_id, stable_id))
    end
    if source_id ~= nil then
        return rows(DB.query(sql .. " WHERE source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(DB.query(sql .. " ORDER BY updated_at ASC;"))
end

--- 全部注解快照连同书名作者（书行缺失时为空串）。
---@return { source_id: string, stable_id: string, payload: string, title: string, authors: string }[]
function NoteDB.allWithBook()
    local result, nrows = DB.query([[SELECT n.source_id, n.stable_id, n.payload,
        COALESCE(b.title, ''), COALESCE(b.authors, '')
        FROM notes n LEFT JOIN books b ON b.source_id=n.source_id AND b.stable_id=n.stable_id
        ORDER BY n.updated_at ASC;]])
    local out = {}
    for i = 1, nrows do
        out[i] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            payload = result[3][i],
            title = result[4][i],
            authors = result[5][i],
        }
    end
    return out
end

--- 表内容戳（行数 + 最新更新时间），变了才需重读全表。
---@return string
function NoteDB.stamp()
    local result, nrows = DB.query("SELECT COUNT(*), MAX(updated_at) FROM notes;")
    return nrows > 0 and (tostring(result[1][1]) .. ":" .. tostring(result[2][1])) or ""
end

--- 列出未同步的本地注解快照。
---@param source_id string|nil
---@return table[]
function NoteDB.unsynced(source_id)
    local sql = "SELECT " .. COLUMNS .. " FROM notes WHERE sync_status=0"
    if source_id ~= nil then
        return rows(DB.query(sql .. " AND source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(DB.query(sql .. " ORDER BY updated_at ASC;"))
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
    local idx = tonumber(chapter_idx)
    if type(idx) ~= "number" then
        idx = 0
    end
    local ts = tonumber(updated_at)
    if payload ~= nil then
        return DB.exec(
            [[UPDATE notes SET sync_status=1, payload=?
              WHERE source_id=? AND stable_id=? AND chapter_idx=? AND updated_at=?;]],
            payload, source_id, stable_id, idx, ts
        ) ~= nil
    end
    return DB.exec(
        [[UPDATE notes SET sync_status=1
          WHERE source_id=? AND stable_id=? AND chapter_idx=? AND updated_at=?;]],
        source_id,
        stable_id,
        idx,
        ts
    ) ~= nil
end

--- 是否有待上传快照：只查存在性，不把整份 payload 读进内存（本地源笔记永远是待上传）。
---@param source_id string
---@return boolean
function NoteDB.hasUnsynced(source_id)
    return DB.rowexec("SELECT 1 FROM notes WHERE sync_status=0 AND source_id=? LIMIT 1;", source_id) ~= nil
end

return NoteDB
