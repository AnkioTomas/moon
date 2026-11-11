--[[--
逐章目录缓存：toc_entries 保存章节，toc_snapshots 保存拉取时间（空目录也有快照）。

身份按 source_id / stable_id 隔离，idx 是目录位置。常用字段直接存列，源专属
字段原样存小 JSON；words / paid 的增量更新不重写目录，也不改变 fetched_at。
revision 用于检测分批冷读期间的快照替换；临时表 toc_incoming 只在写事务内使用，
由 SQLite 保留旧字数 / 已知购买状态，避免把旧目录的长字符串再读回主线程。
替换快照在一个事务中完成，成功后才清旧 books.toc。刷新保留同 uid 的本地字数；
uid 缺失时只有同位置、同标题和地址才沿用，避免重排后把字数挂给别章。

@module koplugin.book.book.toc_db
--]]

local DB = require("utils.db")
local logger = require("utils.log")

local TocDB = {}
local COLUMNS = { idx = true, uid = true, title = true, origin = true,
    words = true, vip = true, paid = true }

DB.schema("toc_entries", function()
    if not DB.exec([[
CREATE TABLE IF NOT EXISTS toc_snapshots (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, fetched_at INTEGER NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (source_id, stable_id)
);
CREATE TABLE IF NOT EXISTS toc_entries (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, idx INTEGER NOT NULL,
  uid TEXT, title TEXT, origin TEXT, words INTEGER, vip INTEGER, paid INTEGER, extra TEXT,
  PRIMARY KEY (source_id, stable_id, idx)
);
CREATE INDEX IF NOT EXISTS toc_entries_uid ON toc_entries(source_id, stable_id, uid);
CREATE TEMP TABLE IF NOT EXISTS toc_incoming (
  idx INTEGER PRIMARY KEY, uid TEXT, title TEXT, origin TEXT,
  words INTEGER, vip INTEGER, paid INTEGER, extra TEXT
);
]]) then return false end
    local columns, count = DB.query("PRAGMA table_info(toc_snapshots);")
    if not columns then return false end
    for i = 1, count do
        if columns[2][i] == "revision" then return true end
    end
    return DB.exec("ALTER TABLE toc_snapshots ADD COLUMN revision INTEGER NOT NULL DEFAULT 1;") ~= nil
end)

local function sqlBoolean(value)
    if value == nil then return nil end
    return value and 1 or 0
end

local function luaBoolean(value)
    if value == nil then return nil end
    return tonumber(value) == 1
end

---@param source_id string
---@param stable_id string
---@return BookChapter[]|nil list
local function decodeRows(source_id, stable_id, rows, count)
    if not rows then return nil end
    local list = {}
    for i = 1, count do
        local entry = {}
        local payload = rows[8] and rows[8][i]
        if payload then
            local decoded, _position, err = require("dkjson").decode(payload)
            if type(decoded) ~= "table" then
                logger.warn("book.toc extra decode failed", source_id, stable_id, i, err or "expected JSON object")
                return nil
            end
            entry = decoded
        end
        entry.idx = tonumber(rows[1][i])
        if entry.uid == nil then entry.uid = rows[2] and rows[2][i] end
        entry.title = rows[3] and rows[3][i]
        entry.origin = rows[4] and rows[4][i]
        entry.words = rows[5] and tonumber(rows[5][i])
        entry.vip = luaBoolean(rows[6] and rows[6][i])
        entry.paid = luaBoolean(rows[7] and rows[7][i])
        list[i] = entry
    end
    return list
end

function TocDB.snapshot(source_id, stable_id)
    local fetched_at, revision = DB.rowexec(
        "SELECT fetched_at, revision FROM toc_snapshots WHERE source_id=? AND stable_id=?;",
        source_id, stable_id)
    return tonumber(fetched_at), tonumber(revision)
end

---@param source_id string
---@param stable_id string
---@return BookChapter[]|nil
---@return integer|nil
function TocDB.read(source_id, stable_id)
    local fetched_at = TocDB.snapshot(source_id, stable_id)
    if fetched_at == nil then return nil end
    local rows, count = DB.query([[SELECT idx, uid, title, origin, words, vip, paid, extra
        FROM toc_entries WHERE source_id=? AND stable_id=? ORDER BY idx;]], source_id, stable_id)
    return decodeRows(source_id, stable_id, rows, count), fetched_at
end

--- 有界冷读，避免一次把上万条相似长字符串带回 Lua。
function TocDB.readPage(source_id, stable_id, after)
    local rows, count = DB.query([[SELECT idx, uid, title, origin, words, vip, paid, extra
        FROM toc_entries WHERE source_id=? AND stable_id=? AND idx>? ORDER BY idx LIMIT 16;]],
        source_id, stable_id, after)
    return decodeRows(source_id, stable_id, rows, count)
end

---@param source_id string
---@param stable_id string
---@param list BookChapter[]
---@param fetched_at integer|nil
---@return boolean
function TocDB.put(source_id, stable_id, list, fetched_at)
    local BookDB = require("book.books_db")
    local encoded = {}
    for i, chapter in ipairs(list) do
        local extra = {}
        for key, value in pairs(chapter) do
            if not COLUMNS[key] or (key == "uid" and type(value) ~= "string") then
                extra[key] = value
            end
        end
        encoded[i] = next(extra) and require("dkjson").encode(extra) or false
    end
    local metadata, metadata_count
    local ok = DB.transaction(function()
        if not DB.exec("DELETE FROM toc_incoming;") then return false end
        local conn = assert(DB.ensure())
        local stmt = conn:prepare([[INSERT INTO toc_incoming
            (idx, uid, title, origin, words, vip, paid, extra) VALUES (?,?,?,?,?,?,?,?);]])
        local wrote, err = pcall(function()
            for i, chapter in ipairs(list) do
                stmt:reset()
                stmt:bind(chapter.idx,
                    chapter.uid and tostring(chapter.uid), chapter.title, chapter.origin,
                    chapter.words, sqlBoolean(chapter.vip), sqlBoolean(chapter.paid),
                    encoded[i] or nil):step()
            end
        end)
        stmt:close()
        if not wrote then
            logger.warn("book.toc write failed", source_id, stable_id, err)
            return false
        end
        -- 固定 UID 索引：旧 SQLite 会为 ORDER BY 选 idx 主键，逐章扫全目录。
        for _idx, field in ipairs({ "words", "paid" }) do
            if not DB.exec("UPDATE toc_incoming SET " .. field .. "=(SELECT " .. field .. [[
                FROM toc_entries INDEXED BY toc_entries_uid
                WHERE source_id=? AND stable_id=? AND uid=toc_incoming.uid ORDER BY idx DESC LIMIT 1)
                WHERE uid IS NOT NULL AND ]] .. field .. " IS NULL;", source_id, stable_id)
                or not DB.exec("UPDATE toc_incoming SET " .. field .. "=(SELECT " .. field .. [[
                FROM toc_entries WHERE source_id=? AND stable_id=? AND uid IS NULL
                AND idx=toc_incoming.idx AND title IS toc_incoming.title AND origin IS toc_incoming.origin)
                WHERE uid IS NULL AND ]] .. field .. " IS NULL;", source_id, stable_id) then return false end
        end
        if not DB.exec("DELETE FROM toc_entries WHERE source_id=? AND stable_id=?;", source_id, stable_id)
            or not DB.exec([[INSERT INTO toc_entries
                (source_id, stable_id, idx, uid, title, origin, words, vip, paid, extra)
                SELECT ?,?,idx,uid,title,origin,words,vip,paid,extra FROM toc_incoming;]], source_id, stable_id)
            or not DB.exec([[INSERT INTO toc_snapshots (source_id, stable_id, fetched_at)
            VALUES (?,?,?) ON CONFLICT(source_id,stable_id)
            DO UPDATE SET fetched_at=excluded.fetched_at, revision=revision+1;]],
                source_id, stable_id, fetched_at or os.time())
            or not BookDB.setToc(source_id, stable_id, nil) then return false end
        metadata, metadata_count = DB.query([[SELECT idx,words,paid FROM toc_incoming
            WHERE words IS NOT NULL OR paid IS NOT NULL;]])
        return metadata ~= nil and DB.exec("DELETE FROM toc_incoming;")
    end) == true
    if ok then
        local by_idx = {}
        for _idx, chapter in ipairs(list) do by_idx[chapter.idx] = chapter end
        for i = 1, metadata_count do
            local chapter = by_idx[tonumber(metadata[1][i])]
            chapter.words = metadata[2] and tonumber(metadata[2][i])
            chapter.paid = luaBoolean(metadata[3] and metadata[3][i])
        end
    end
    return ok
end

---@param source_id string
---@param stable_id string
---@param idx integer
---@param field "words"|"paid"
---@param value integer|boolean
---@return boolean
function TocDB.update(source_id, stable_id, idx, field, value)
    assert(field == "words" or field == "paid", "invalid toc field")
    if field == "paid" then value = sqlBoolean(value) end
    return DB.exec("UPDATE toc_entries SET " .. field
        .. "=? WHERE source_id=? AND stable_id=? AND idx=?;", value, source_id, stable_id, idx) ~= nil
end

function TocDB.removeIdentity(source_id, stable_id)
    local ok = DB.removeIdentity("toc_entries", source_id, stable_id)
        and DB.removeIdentity("toc_snapshots", source_id, stable_id)
    if ok then require("source.toc").invalidate(source_id, stable_id) end
    return ok
end

function TocDB.removeSource(source_id, stable_prefix, exclude)
    local ok = DB.removeSource("toc_entries", source_id, stable_prefix, exclude)
        and DB.removeSource("toc_snapshots", source_id, stable_prefix, exclude)
    if ok then require("source.toc").clear() end
    return ok
end

function TocDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    if merge and DB.rowexec("SELECT 1 FROM toc_snapshots WHERE source_id=? AND stable_id=?;",
        source_id, new_stable_id) then
        return TocDB.removeIdentity(source_id, old_stable_id)
    end
    local ok = DB.moveIdentity("toc_entries", source_id, old_stable_id, new_stable_id, false)
        and DB.moveIdentity("toc_snapshots", source_id, old_stable_id, new_stable_id, false)
    if ok then
        local Toc = require("source.toc")
        Toc.invalidate(source_id, old_stable_id)
        Toc.invalidate(source_id, new_stable_id)
    end
    return ok
end

return TocDB
