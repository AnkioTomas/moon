--[[--
X-Ray 书级实体，以及全书分析的续扫游标。

xray_scan 每本书至多一行：digest 是全书正文临时文件的指纹（字节数:段数），done 是已落库的段数；
正文变了（换了排版版、书被更新）指纹对不上就从头分析。全书分析完成即删行。

@module koplugin.book.features.xray.db
--]]

local DB = require("utils.db")
local Text = require("utils.text")

local XrayDB = {}

DB.schema("xray_entities", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS xray_entities (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, kind TEXT NOT NULL,
  name TEXT NOT NULL, aliases TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
  gender TEXT NOT NULL DEFAULT '', occupation TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id, kind, name)
);
CREATE INDEX IF NOT EXISTS idx_xray_entities_book
  ON xray_entities(source_id, stable_id, kind);
]]) ~= nil
end)

DB.schema("xray_scan", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS xray_scan (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL,
  digest TEXT NOT NULL, done INTEGER NOT NULL, total INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id)
);
]]) ~= nil
end)

-- 用户删掉的实体（名字与别名，小写去空白）：之后的 AI 识别不再把它们加回来。
DB.schema("xray_removed", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS xray_removed (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
  PRIMARY KEY (source_id, stable_id, kind, name)
);
]]) ~= nil
end)

-- 已按章识别过的目录章序号，自动预取据此不重复花 token。
DB.schema("xray_chapter", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS xray_chapter (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, chapter_idx INTEGER NOT NULL,
  PRIMARY KEY (source_id, stable_id, chapter_idx)
);
]]) ~= nil
end)

--- 全书分析的续扫游标；没有时 nil。
---@param source_id string
---@param stable_id string
---@return { digest: string, done: integer, total: integer }|nil
function XrayDB.scanCursor(source_id, stable_id)
    local digest, done, total = DB.rowexec(
        "SELECT digest, done, total FROM xray_scan WHERE source_id=? AND stable_id=?;", source_id, stable_id)
    if not digest then return nil end
    return { digest = digest, done = tonumber(done) or 0, total = tonumber(total) or 0 }
end

---@param source_id string
---@param stable_id string
---@param digest string
---@param done integer 已落库的段数
---@param total integer
---@return boolean
function XrayDB.saveScanCursor(source_id, stable_id, digest, done, total)
    return DB.exec([[
        INSERT INTO xray_scan (source_id, stable_id, digest, done, total) VALUES (?,?,?,?,?)
        ON CONFLICT(source_id, stable_id) DO UPDATE SET
          digest=excluded.digest, done=excluded.done, total=excluded.total;
    ]], source_id, stable_id, digest, done, total) ~= nil
end

---@param source_id string
---@param stable_id string
---@return boolean
function XrayDB.clearScanCursor(source_id, stable_id)
    return DB.removeIdentity("xray_scan", source_id, stable_id)
end

local function splitAliases(encoded)
    local aliases = {}
    local start = 1
    while true do
        local first, last = string.find(encoded, "、", start, true)
        if not first then
            if start <= #encoded then
                aliases[#aliases + 1] = encoded:sub(start)
            end
            return aliases
        end
        aliases[#aliases + 1] = encoded:sub(start, first - 1)
        start = last + 1
    end
end

--- 写入或覆盖一个 X-Ray 实体。
---@param source_id string
---@param stable_id string
---@param entity table { kind, name, aliases, role, description, gender, occupation }
---@param updated_at integer|nil
---@return boolean
function XrayDB.upsert(source_id, stable_id, entity, updated_at)
    local aliases = table.concat(entity.aliases, "、")
    return DB.exec([[
        INSERT INTO xray_entities
          (source_id, stable_id, kind, name, aliases, role, description,
           gender, occupation, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(source_id, stable_id, kind, name) DO UPDATE SET
          aliases=excluded.aliases,
          role=excluded.role,
          description=excluded.description,
          gender=excluded.gender,
          occupation=excluded.occupation,
          updated_at=excluded.updated_at;
    ]], source_id, stable_id, entity.kind, entity.name, aliases,
        entity.role or "", entity.description or "", entity.gender or "",
        entity.occupation or "", tonumber(updated_at) or os.time()) ~= nil
end

--- 列出实体；kind 非空时按种类过滤。
---@param source_id string
---@param stable_id string
---@param kind string|nil
---@return table[]
function XrayDB.list(source_id, stable_id, kind)
    local sql = [[
            SELECT kind, name, aliases, role, description, gender, occupation, updated_at
            FROM xray_entities
            WHERE source_id=? AND stable_id=?]]
    local result, nrows
    if kind and kind ~= "" then
        result, nrows = DB.query(sql .. " AND kind=? ORDER BY name COLLATE NOCASE ASC;", source_id, stable_id, kind)
    else
        result, nrows = DB.query(sql .. " ORDER BY kind ASC, name COLLATE NOCASE ASC;", source_id, stable_id)
    end
    local out = {}
    for i = 1, nrows do
        out[#out + 1] = {
            kind = result[1][i],
            name = result[2][i],
            aliases = splitAliases(result[3][i]),
            role = result[4][i],
            description = result[5][i],
            gender = result[6][i],
            occupation = result[7][i],
            updated_at = tonumber(result[8][i]) or 0,
        }
    end
    return out
end

---@param name string
---@return string
local function tombName(name)
    return Text.trim(name):lower()
end

--- 删除实体并把它的名字与别名记入墓碑。
---@param source_id string
---@param stable_id string
---@param entity table { kind, name, aliases }
---@return boolean
function XrayDB.remove(source_id, stable_id, entity)
    return DB.transaction(function()
        if not DB.exec("DELETE FROM xray_entities WHERE source_id=? AND stable_id=? AND kind=? AND name=?;",
                source_id, stable_id, entity.kind, entity.name) then
            return false
        end
        local names = { entity.name }
        for _idx, alias in ipairs(entity.aliases or {}) do names[#names + 1] = alias end
        for _idx, name in ipairs(names) do
            if not DB.exec("INSERT OR IGNORE INTO xray_removed (source_id, stable_id, kind, name) VALUES (?,?,?,?);",
                    source_id, stable_id, entity.kind, tombName(name)) then
                return false
            end
        end
        return true
    end) == true
end

--- 墓碑集合：键为 kind\0小写名。
---@param source_id string
---@param stable_id string
---@return table<string, true>
function XrayDB.removedSet(source_id, stable_id)
    local result, nrows = DB.query(
        "SELECT kind, name FROM xray_removed WHERE source_id=? AND stable_id=?;", source_id, stable_id)
    local out = {}
    for i = 1, nrows do out[result[1][i] .. "\0" .. result[2][i]] = true end
    return out
end

--- 用户手动要回某个名字：清掉它的墓碑。
---@param source_id string
---@param stable_id string
---@param kind string
---@param name string
---@return boolean
function XrayDB.restore(source_id, stable_id, kind, name)
    return DB.exec("DELETE FROM xray_removed WHERE source_id=? AND stable_id=? AND kind=? AND name=?;",
        source_id, stable_id, kind, tombName(name)) ~= nil
end

---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@return boolean
function XrayDB.chapterDone(source_id, stable_id, chapter_idx)
    return DB.rowexec("SELECT 1 FROM xray_chapter WHERE source_id=? AND stable_id=? AND chapter_idx=?;",
        source_id, stable_id, chapter_idx) ~= nil
end

---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@return boolean
function XrayDB.markChapter(source_id, stable_id, chapter_idx)
    return DB.exec("INSERT OR IGNORE INTO xray_chapter (source_id, stable_id, chapter_idx) VALUES (?,?,?);",
        source_id, stable_id, chapter_idx) ~= nil
end

--- 原子替换一本书的全部 X-Ray 实体。
---@param source_id string
---@param stable_id string
---@param entities table[]
---@param updated_at integer|nil
---@return boolean
function XrayDB.replace(source_id, stable_id, entities, updated_at)
    return DB.transaction(function()
        if not DB.exec([[DELETE FROM xray_entities WHERE source_id=? AND stable_id=?;]],
                source_id, stable_id) then
            return false
        end
        local stamp = updated_at or os.time()
        for _idx, entity in ipairs(entities) do
            if not XrayDB.upsert(source_id, stable_id, entity, stamp) then return false end
        end
        return true
    end) == true
end

return XrayDB
