--[[--
本地阅读进度（一书一条），阅读进度真源。sync_status=0 表示待上传，1 表示已同步。
表名带 pending_，但行同时表示已同步状态。

不变量：
  - upsertRemote 的 keep_dirty 必须在落库前判定，本地脏行整行跳过；冲突交给开书时用户选择，禁止静默抹平。
  - markSynced 靠 updated_at 乐观锁，推送期间又更新过的行不会被误标已同步。
  - 进度写到 100% 调 BookDB.markReadAutomatically（books 自动标已读）；建表时对已读完的行回填一次。
books_db 调用：markFinished（手动已读补 100% 待上传进度）、moveIdentity（迁身份）。

@module koplugin.book.book.progress_db
--]]

--- 对应表 pending_progress：待上传进度（一书一条）
---@class PendingProgress : ProgressPosition
---@field source_id string PRIMARY KEY 与 stable_id 复合主键
---@field stable_id string PRIMARY KEY 与 source_id 复合主键
---@field fraction number 全书比例
---@field chapter_idx integer|nil 章节序号；部分源没有
---@field chapter_title string|nil 当前章节标题
---@field chapter_fraction number|nil 章内比例
---@field page integer|nil 当前文档页码（1-based）
---@field total_pages integer|nil 当前文档总页数
---@field locator string|nil XPointer/CFI 等精确定位
---@field extra table|nil 源私有定位字段（JSON 落库），如微信 chapter_uid
---@field updated_at integer 更新时间戳
---@field sync_status integer 0=待同步，1=已同步

local DB = require("utils.db")
local JSON = require("json")
local logger = require("utils.log")
local BookDB = require("book.books_db")

local ProgressDB = {}

DB.schema("pending_progress", function()
    if not DB.exec([[
CREATE TABLE IF NOT EXISTS pending_progress (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, fraction REAL NOT NULL,
  chapter_idx INTEGER, chapter_title TEXT, chapter_fraction REAL,
  page INTEGER, total_pages INTEGER, locator TEXT, extra TEXT,
  updated_at INTEGER NOT NULL, sync_status INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id)
);
CREATE INDEX IF NOT EXISTS idx_pending_progress_recent
  ON pending_progress(source_id, updated_at DESC);
]]) then return false end
    -- 旧库回填：read_state 列加入前已读完的书。
    local result, nrows = DB.query("SELECT source_id, stable_id FROM pending_progress WHERE fraction>=1;")
    for i = 1, nrows do
        if not BookDB.markReadAutomatically(result[1][i], result[2][i]) then return false end
    end
    return true
end)

local COLUMNS = "source_id, stable_id, fraction, chapter_idx, chapter_title, chapter_fraction, page, total_pages, locator, extra, updated_at, sync_status"

---@return integer|nil
local function positiveInt(value)
    local n = tonumber(value)
    if not n or n < 1 then
        return nil
    end
    return math.floor(n)
end

--- 源私有定位字段序列化为 JSON；空表与非表一律存 NULL。
---@param extra table|nil
---@return string|nil payload, any err 编码失败时 payload 为 nil、err 非空
local function encodeExtra(extra)
    if not extra or next(extra) == nil then
        return nil
    end
    local ok, payload = pcall(JSON.encode, extra)
    if not ok then
        logger.warn("book.db progress extra encode failed", payload)
        return nil, payload
    end
    return payload
end

---@return table|nil
local function decodeExtra(payload)
    local ok, extra = pcall(JSON.decode, payload)
    if not ok then
        return nil
    end
    return extra
end

--- 三种写入只差同步状态与「是否允许覆盖脏版本」，SQL 其余部分完全相同。
---@param source_id string
---@param stable_id string
---@param pos ProgressPosition
---@param status integer 落库后的 sync_status
---@param keep_dirty boolean|nil 为真时不覆盖 sync_status=0 的本地脏版本
---@return boolean
local function write(source_id, stable_id, pos, status, keep_dirty)
    local fraction = tonumber(pos.fraction)
    -- keep_dirty：本地脏行整行跳过，避免远端覆盖。
    if keep_dirty and tonumber(DB.rowexec(
            "SELECT sync_status FROM pending_progress WHERE source_id=? AND stable_id=?;",
            source_id, stable_id)) == 0 then
        return true
    end
    -- extra 是源私有定位，丢了会让下次恢复落到错误位置，不能静默写 NULL 当成功。
    local extra, extra_err = encodeExtra(pos.extra)
    if extra_err then
        return false
    end
    if not DB.exec(
        [[INSERT INTO pending_progress
            (source_id, stable_id, fraction, chapter_idx, chapter_title, chapter_fraction,
             page, total_pages, locator, extra, updated_at, sync_status)
          VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
          ON CONFLICT(source_id, stable_id) DO UPDATE SET
            fraction=excluded.fraction,
            chapter_idx=excluded.chapter_idx,
            chapter_title=excluded.chapter_title,
            chapter_fraction=excluded.chapter_fraction,
            page=excluded.page,
            total_pages=excluded.total_pages,
            locator=excluded.locator,
            extra=excluded.extra,
            updated_at=MAX(excluded.updated_at, pending_progress.updated_at),
            sync_status=excluded.sync_status;]],
        source_id, stable_id, fraction, pos.chapter_idx, pos.chapter_title, pos.chapter_fraction,
        positiveInt(pos.page), positiveInt(pos.total_pages),
        pos.locator, extra,
        tonumber(pos.updated_at) or (status == 0 and os.time() or 0), status
    ) then
        return false
    end
    -- 进度真源在本表；books.read_state 失败不影响进度落库。
    if (fraction or 0) >= 1 then BookDB.markReadAutomatically(source_id, stable_id) end
    return true
end

--- 保存本地阅读进度，标记为待同步。
---@param source_id string
---@param stable_id string
---@param pos ProgressPosition
---@return boolean
function ProgressDB.upsert(source_id, stable_id, pos)
    return write(source_id, stable_id, pos, 0)
end

--- 保存远端进度。未同步的本地版本不允许被远端覆盖。
---@param source_id string
---@param stable_id string
---@param pos ProgressPosition
---@return boolean
function ProgressDB.upsertRemote(source_id, stable_id, pos)
    return write(source_id, stable_id, pos, 1, true)
end

--- 用户确认采用远端进度：无条件覆盖本地（含 sync_status=0 的脏版本）。
---@param source_id string
---@param stable_id string
---@param pos ProgressPosition
---@return boolean
function ProgressDB.adoptRemote(source_id, stable_id, pos)
    return write(source_id, stable_id, pos, 1)
end

--- COLUMNS 顺序的位置参数 → PendingProgress
---@return PendingProgress|nil
local function toProgress(source, stable, fraction, chapter_idx, chapter_title, chapter_fraction,
                          page, total_pages, locator, extra, updated_at, sync_status)
    if not source then
        return nil
    end
    return {
        source_id = source,
        stable_id = stable,
        fraction = tonumber(fraction) or 0,
        chapter_idx = tonumber(chapter_idx),
        chapter_title = chapter_title ~= "" and chapter_title or nil,
        chapter_fraction = tonumber(chapter_fraction),
        page = tonumber(page),
        total_pages = tonumber(total_pages),
        locator = locator,
        extra = decodeExtra(extra),
        updated_at = tonumber(updated_at) or 0,
        sync_status = tonumber(sync_status) or 0,
    }
end

---@param source_id string
---@param stable_id string
---@return PendingProgress|nil
function ProgressDB.get(source_id, stable_id)
    return toProgress(DB.rowexec(
        "SELECT " .. COLUMNS .. " FROM pending_progress WHERE source_id=? AND stable_id=? LIMIT 1;",
        source_id,
        stable_id
    ))
end

---@param result table|nil
---@param nrows integer
---@return PendingProgress[]
local function rows(result, nrows)
    local out = {}
    for i = 1, nrows do
        local row = {}
        for c = 1, 12 do row[c] = result[c][i] end
        out[i] = toProgress(unpack(row, 1, 12))
    end
    return out
end

---@param source_id string
---@return PendingProgress[]
function ProgressDB.unsynced(source_id)
    return rows(DB.query(
        "SELECT " .. COLUMNS .. " FROM pending_progress WHERE sync_status=0 AND source_id=? ORDER BY updated_at ASC;",
        source_id
    ))
end

--- 当前书库中有阅读进度的书，按进度更新时间倒序。
--- books 只负责成员资格；最近阅读的准入与排序完全由 pending_progress 决定。
--- source_id 可为单源字符串，或已启用源 id 列表（混合模式）。
---@param source_id string|string[]
---@param limit number|nil
---@return PendingProgress[]
function ProgressDB.recent(source_id, limit)
    local where, args = DB.sourceClause("p.source_id", source_id)
    args[#args + 1] = math.max(1, tonumber(limit) or 24)
    return rows(DB.query(
        [[SELECT ]] .. COLUMNS .. [[ FROM pending_progress p
          WHERE ]] .. where .. [[ AND p.updated_at>0
            AND EXISTS (
              SELECT 1 FROM books b
               WHERE b.source_id=p.source_id AND b.stable_id=p.stable_id
                 AND b.deleted=0
            )
          ORDER BY p.updated_at DESC, p.stable_id ASC LIMIT ?;]],
        unpack(args)
    ))
end

---@param source_id string
---@param stable_id string
---@param updated_at number
---@return boolean 命中该修订号的行才算确认；期间被改写过返回 false
function ProgressDB.markSynced(source_id, stable_id, updated_at)
    return DB.exec(
        [[UPDATE pending_progress SET sync_status=1
          WHERE source_id=? AND stable_id=? AND updated_at=?;]],
        source_id,
        stable_id,
        updated_at
    ) ~= nil and (tonumber(DB.rowexec("SELECT changes();")) or 0) > 0
end

--- 手动标已读（BookDB.setRead）：补一条 100% 的待上传进度。
---@param source_id string
---@param stable_id string
---@return boolean
function ProgressDB.markFinished(source_id, stable_id)
    return DB.exec([[
INSERT INTO pending_progress
  (source_id, stable_id, fraction, updated_at, sync_status)
VALUES (?,?,1,?,0)
ON CONFLICT(source_id, stable_id) DO UPDATE SET
  fraction=1,
  sync_status=0,
  updated_at=MAX(excluded.updated_at, pending_progress.updated_at + 1);]],
        -- 修订号是 markSynced 的乐观锁，撞上在飞推送的那一版会被误标已同步。
        -- book.progress 顶层 require 本模块，只能在这里延迟加载。
        source_id, stable_id, require("book.progress").nextRevision()) ~= nil
end

--- 书改名 / 收编时由 books_db 调用。
--- 收编（merge）时旧身份的进度还没推就比新身份的已同步副本新，先清掉新身份那份。
function ProgressDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    return (not merge or DB.exec(
        [[DELETE FROM pending_progress WHERE source_id=? AND stable_id=? AND EXISTS (
            SELECT 1 FROM pending_progress WHERE source_id=? AND stable_id=? AND sync_status=0);]],
        source_id, new_stable_id, source_id, old_stable_id) ~= nil)
        and DB.moveIdentity("pending_progress", source_id, old_stable_id, new_stable_id, merge)
end

--- 书被删（墓碑撕掉）时由 books_db 调用。
function ProgressDB.removeIdentity(source_id, stable_id)
    return DB.removeIdentity("pending_progress", source_id, stable_id)
end

return ProgressDB
