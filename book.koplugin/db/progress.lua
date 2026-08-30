--[[--
本地阅读进度（一书一条）。sync_status=0 表示待上传，1 表示已同步。

@module koplugin.book.db.progress
--]]

local Base = require("db.base")
local Book = require("types.book").Book
local JSON = require("json")
local logger = require("logger")

local ProgressDB = {}

--- 创建本地阅读进度表。
--- 仅在 Base.open() 的一次性 schema 初始化阶段调用。
---@return boolean 成功返回 true，SQL 失败返回 false
function ProgressDB.ensureSchema()
    if not Base.exec([[
CREATE TABLE IF NOT EXISTS pending_progress (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, fraction REAL NOT NULL,
  chapter_idx INTEGER, chapter_title TEXT, chapter_fraction REAL,
  page INTEGER, total_pages INTEGER, locator TEXT, extra TEXT,
  updated_at INTEGER NOT NULL, sync_status INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, stable_id)
);
]]) then return false end
    return true
end

local COLUMNS = "source_id, stable_id, fraction, chapter_idx, chapter_title, chapter_fraction, page, total_pages, locator, extra, updated_at, sync_status"

---@param value any
---@return integer|nil
local function positiveInt(value)
    local n = tonumber(value)
    if not n or n < 1 then
        return nil
    end
    return math.floor(n)
end

--- 进度落盘后同步 books.percent，避免只读 books 表的 UI 显示旧值。
---@param source_id string
---@param stable_id string
---@param fraction number
local function syncBookPercent(source_id, stable_id, fraction)
    local percent = Book.clampPercent(fraction, false, true)
    Base.exec(
        [[UPDATE books SET percent=? WHERE source_id=? AND stable_id=?;]],
        percent,
        source_id,
        stable_id
    )
end

--- 源私有定位字段序列化为 JSON；空表与非表一律存 NULL。
---@param extra table|nil
---@return string|nil
local function encodeExtra(extra)
    if not extra or next(extra) == nil then
        return nil
    end
    local ok, payload = pcall(JSON.encode, extra)
    if not ok then
        logger.warn("book.db progress extra encode failed", payload)
        return nil
    end
    return payload
end

---@param payload any
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
    -- keep_dirty 必须在这里判定：靠 SQL 的 WHERE 只能让 UPDATE 静默 no-op，
    -- 下面的 syncBookPercent 仍会把 books.percent 改成远端值，
    -- 于是 pending_progress 是本地进度、books.percent 是云端进度，两处显示打架。
    -- 本地版本更新算正常结果，返回 true（调用方 assert 成功）。
    if keep_dirty and tonumber(Base.rowexec(
            "SELECT sync_status FROM pending_progress WHERE source_id=? AND stable_id=?;",
            source_id, stable_id)) == 0 then
        return true
    end
    if not Base.exec(
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
            updated_at=excluded.updated_at,
            sync_status=excluded.sync_status;]],
        source_id, stable_id, fraction, pos.chapter_idx, pos.chapter_title, pos.chapter_fraction,
        positiveInt(pos.page), positiveInt(pos.total_pages),
        pos.locator, encodeExtra(pos.extra), tonumber(pos.updated_at) or os.time(), status
    ) then
        return false
    end
    syncBookPercent(source_id, stable_id, fraction)
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

---@param source_id string
---@param stable_id string
---@return PendingProgress|nil
function ProgressDB.get(source_id, stable_id)
    local source, stable, fraction, chapter_idx, chapter_title, chapter_fraction,
        page, total_pages, locator, extra, updated_at, sync_status = Base.rowexec(
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
        chapter_title = chapter_title ~= "" and chapter_title or nil,
        chapter_fraction = chapter_fraction ~= nil and tonumber(chapter_fraction) or nil,
        page = page ~= nil and tonumber(page) or nil,
        total_pages = total_pages ~= nil and tonumber(total_pages) or nil,
        locator = locator,
        extra = decodeExtra(extra),
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
        local title = result[5][i]
        out[#out + 1] = {
            source_id = result[1][i],
            stable_id = result[2][i],
            fraction = tonumber(result[3][i]) or 0,
            chapter_idx = result[4][i] ~= nil and tonumber(result[4][i]) or nil,
            chapter_title = title ~= "" and title or nil,
            chapter_fraction = result[6][i] ~= nil and tonumber(result[6][i]) or nil,
            page = result[7][i] ~= nil and tonumber(result[7][i]) or nil,
            total_pages = result[8][i] ~= nil and tonumber(result[8][i]) or nil,
            locator = result[9][i],
            extra = decodeExtra(result[10][i]),
            updated_at = tonumber(result[11][i]) or 0,
            sync_status = tonumber(result[12] and result[12][i]) or 0,
        }
    end
    return out
end

---@param source_id string|nil
---@return PendingProgress[]
function ProgressDB.all(source_id)
    local sql = "SELECT " .. COLUMNS .. " FROM pending_progress"
    if source_id ~= nil then
        return rows(Base.query(sql .. " WHERE source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(Base.query(sql .. " ORDER BY updated_at ASC;"))
end

---@param source_id string|nil
---@return PendingProgress[]
function ProgressDB.unsynced(source_id)
    local sql = "SELECT " .. COLUMNS .. " FROM pending_progress WHERE sync_status=0"
    if source_id ~= nil then
        return rows(Base.query(sql .. " AND source_id=? ORDER BY updated_at ASC;", source_id))
    end
    return rows(Base.query(sql .. " ORDER BY updated_at ASC;"))
end

---@param source_id string
---@param stable_id string
---@param updated_at number
---@return boolean
function ProgressDB.markSynced(source_id, stable_id, updated_at)
    updated_at = tonumber(updated_at)
    return Base.exec(
        [[UPDATE pending_progress SET sync_status=1
          WHERE source_id=? AND stable_id=? AND updated_at=?;]],
        source_id,
        stable_id,
        updated_at
    ) ~= nil
end

return ProgressDB
