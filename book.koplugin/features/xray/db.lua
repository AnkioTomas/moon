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

-- 情节线：title 是情节线名，每行是它的一个先后发生的节点；time 是正文里写明的故事内时间（没有为空串），
-- pos 是节点在全书中的位置（阅读进度百分比）。同情节线同描述只收一次。
DB.schema("xray_plots", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS xray_plots (
  source_id TEXT NOT NULL, stable_id TEXT NOT NULL, title TEXT NOT NULL,
  time TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '', characters TEXT NOT NULL DEFAULT '',
  pos REAL NOT NULL,
  PRIMARY KEY (source_id, stable_id, title, description)
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

--- 每本书的情节线数与节点数上限：模型把场景当情节线乱吐时兜底。
local MAX_PLOTS = 20
local MAX_NODES = 400

--- 追加情节节点；同情节线同描述的忽略，新情节线与节点满额后不再收（已有情节线的节点仍可追加到节点上限）。
---@param source_id string
---@param stable_id string
---@param events { title: string, time: string, description: string, characters: string[], pos: number }[]
---@return boolean
function XrayDB.addEvents(source_id, stable_id, events)
    if #events == 0 then return true end
    return DB.transaction(function()
        local known, plots = {}, 0
        local result, nrows = DB.query(
            "SELECT DISTINCT title FROM xray_plots WHERE source_id=? AND stable_id=?;", source_id, stable_id)
        for i = 1, nrows or 0 do
            known[result[1][i]] = true
            plots = plots + 1
        end
        local count = tonumber(DB.rowexec(
            "SELECT COUNT(*) FROM xray_plots WHERE source_id=? AND stable_id=?;", source_id, stable_id)) or 0
        for _idx, event in ipairs(events) do
            if count >= MAX_NODES then break end
            if not known[event.title] and plots < MAX_PLOTS then
                known[event.title] = true
                plots = plots + 1
            end
            if known[event.title] then
                if not DB.exec([[INSERT OR IGNORE INTO xray_plots
                    (source_id, stable_id, title, time, description, characters, pos) VALUES (?,?,?,?,?,?,?);]],
                        source_id, stable_id, event.title, event.time, event.description,
                        table.concat(event.characters, "、"), event.pos) then
                    return false
                end
                count = count + 1
            end
        end
        return true
    end) == true
end

--- 按发生顺序（位置，再按写入先后）列出这本书的全部情节节点。
---@param source_id string
---@param stable_id string
---@return { title: string, time: string, description: string, characters: string[], pos: number }[]
function XrayDB.listEvents(source_id, stable_id)
    local result, nrows = DB.query([[SELECT title, time, description, characters, pos FROM xray_plots
        WHERE source_id=? AND stable_id=? ORDER BY pos ASC, rowid ASC;]], source_id, stable_id)
    local out = {}
    for i = 1, nrows do
        out[i] = {
            title = result[1][i],
            time = result[2][i],
            description = result[3][i],
            characters = splitAliases(result[4][i]),
            pos = tonumber(result[5][i]) or 0,
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

--- 清掉这本书全部墓碑：显式「重新生成 / 分析全书 / 识别本章」时调用，让删过的实体能再被收录。
--- 自动预取不调这个，单删的屏蔽仍然有效。
---@param source_id string
---@param stable_id string
---@return boolean
function XrayDB.clearRemoved(source_id, stable_id)
    return DB.removeIdentity("xray_removed", source_id, stable_id)
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

-- 这本书的全部 X-Ray 状态。改身份、撕墓碑都只认这一份。
local TABLES = { "xray_entities", "xray_scan", "xray_removed", "xray_chapter", "xray_plots" }

--- 书改名 / 收编。不另起事务，跑在调用方事务里。
---@param source_id string
---@param old_stable_id string
---@param new_stable_id string
---@param merge boolean|nil
---@return boolean
function XrayDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    for _idx, tbl in ipairs(TABLES) do
        if not DB.moveIdentity(tbl, source_id, old_stable_id, new_stable_id, merge) then
            return false
        end
    end
    return true
end

--- 撕墓碑。不另起事务：BookDB.remove 已经在事务里，这里再 BEGIN 会直接失败。
---@param source_id string
---@param stable_id string
---@return boolean
function XrayDB.removeIdentity(source_id, stable_id)
    for _idx, tbl in ipairs(TABLES) do
        if not DB.removeIdentity(tbl, source_id, stable_id) then return false end
    end
    return true
end

--- 清空这本书的全部 X-Ray 数据，包括实体、续扫游标、墓碑和已识别章节。
---@param source_id string
---@param stable_id string
---@return boolean
function XrayDB.reset(source_id, stable_id)
    return DB.transaction(function()
        for _idx, tbl in ipairs(TABLES) do
            if not DB.removeIdentity(tbl, source_id, stable_id) then return false end
        end
        return true
    end) == true
end

--- 有 X-Ray 数据的书（续扫游标是本机的，不算）。
---@return { source_id: string, stable_id: string }[]
function XrayDB.books()
    local result, nrows = DB.query([[
        SELECT source_id, stable_id FROM xray_entities
        UNION SELECT source_id, stable_id FROM xray_removed
        UNION SELECT source_id, stable_id FROM xray_plots
        UNION SELECT source_id, stable_id FROM xray_chapter;]])
    local out = {}
    for i = 1, nrows or 0 do out[i] = { source_id = result[1][i], stable_id = result[2][i] } end
    return out
end

---@param sql string
---@param width integer
---@param source_id string
---@param stable_id string
---@return table[]
local function rowsOf(sql, width, source_id, stable_id)
    local result, nrows = DB.query(sql, source_id, stable_id)
    local out = {}
    for i = 1, nrows or 0 do
        local row = {}
        for c = 1, width do row[c] = result[c][i] end
        out[i] = row
    end
    return out
end

--- 一本书的 X-Ray 快照：{ 实体, 墓碑, 情节节点, 已识别章 }，每行是数组，同样的内容编码出同样的串。
--- 续扫游标只对本机正文有效，不在里面。没有任何数据返回 nil。
---@param source_id string
---@param stable_id string
---@return table[]|nil data
---@return integer updated_at 实体最后写入时刻
function XrayDB.export(source_id, stable_id)
    local entities = rowsOf([[SELECT kind, name, aliases, role, description, gender, occupation, updated_at
        FROM xray_entities WHERE source_id=? AND stable_id=? ORDER BY kind, name;]], 8, source_id, stable_id)
    local removed = rowsOf([[SELECT kind, name FROM xray_removed
        WHERE source_id=? AND stable_id=? ORDER BY kind, name;]], 2, source_id, stable_id)
    local plots = rowsOf([[SELECT title, time, description, characters, pos FROM xray_plots
        WHERE source_id=? AND stable_id=? ORDER BY pos, rowid;]], 5, source_id, stable_id)
    local chapters = {}
    for i, row in ipairs(rowsOf([[SELECT chapter_idx FROM xray_chapter
            WHERE source_id=? AND stable_id=? ORDER BY chapter_idx;]], 1, source_id, stable_id)) do
        chapters[i] = tonumber(row[1])
    end
    if #entities + #removed + #plots + #chapters == 0 then return nil, 0 end
    local updated_at = 0
    for _idx, row in ipairs(entities) do
        row[8] = tonumber(row[8]) or 0
        updated_at = math.max(updated_at, row[8])
    end
    for _idx, row in ipairs(plots) do row[5] = tonumber(row[5]) or 0 end
    return { entities, removed, plots, chapters }, updated_at
end

--- 用快照整本替换这本书的 X-Ray（空快照即清空）。续扫游标对不上新数据，一并作废。
--- 快照来自远端，字段按列类型收拾，缺的填空串 / 0。
---@param source_id string
---@param stable_id string
---@param data table
---@return boolean
function XrayDB.import(source_id, stable_id, data)
    local function str(v) return type(v) == "string" and v or "" end
    local function rows(i) return type(data[i]) == "table" and data[i] or {} end
    return DB.transaction(function()
        for _idx, tbl in ipairs(TABLES) do
            if not DB.removeIdentity(tbl, source_id, stable_id) then return false end
        end
        for _idx, r in ipairs(rows(1)) do
            if type(r) == "table" and str(r[1]) ~= "" and str(r[2]) ~= "" and not DB.exec([[INSERT OR REPLACE INTO
                    xray_entities (source_id, stable_id, kind, name, aliases, role, description, gender, occupation,
                    updated_at) VALUES (?,?,?,?,?,?,?,?,?,?);]], source_id, stable_id, r[1], r[2], str(r[3]),
                    str(r[4]), str(r[5]), str(r[6]), str(r[7]), tonumber(r[8]) or 0) then
                return false
            end
        end
        for _idx, r in ipairs(rows(2)) do
            if type(r) == "table" and str(r[1]) ~= "" and str(r[2]) ~= "" and not DB.exec(
                    "INSERT OR IGNORE INTO xray_removed (source_id, stable_id, kind, name) VALUES (?,?,?,?);",
                    source_id, stable_id, r[1], r[2]) then
                return false
            end
        end
        for _idx, r in ipairs(rows(3)) do
            if type(r) == "table" and str(r[1]) ~= "" and not DB.exec([[INSERT OR IGNORE INTO xray_plots
                    (source_id, stable_id, title, time, description, characters, pos) VALUES (?,?,?,?,?,?,?);]],
                    source_id, stable_id, r[1], str(r[2]), str(r[3]), str(r[4]), tonumber(r[5]) or 0) then
                return false
            end
        end
        for _idx, idx in ipairs(rows(4)) do
            if tonumber(idx) and not DB.exec(
                    "INSERT OR IGNORE INTO xray_chapter (source_id, stable_id, chapter_idx) VALUES (?,?,?);",
                    source_id, stable_id, math.floor(tonumber(idx))) then
                return false
            end
        end
        return true
    end) == true
end

--- 退出登录：删掉这个源的全部 X-Ray 行。不另起事务。
---@param source_id string
---@return boolean
function XrayDB.removeSource(source_id, stable_prefix, exclude)
    for _idx, tbl in ipairs(TABLES) do
        if not DB.removeSource(tbl, source_id, stable_prefix, exclude) then return false end
    end
    return true
end

return XrayDB
