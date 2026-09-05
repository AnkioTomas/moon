--[[--
X-Ray 书级实体。

@module koplugin.book.db.xray
--]]

local Base = require("db.base")

local XrayDB = {}

--- 创建 X-Ray 实体表及按书籍身份查询的索引。
--- 仅在 Base.open() 的一次性 schema 初始化阶段调用。
---@return boolean 成功返回 true，SQL 失败返回 false
function XrayDB.ensureSchema()
    if not Base.exec([[
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
]]) then return false end
    return true
end

local function joinAliases(aliases)
    return table.concat(aliases, "、")
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
    local aliases = joinAliases(entity.aliases)
    return Base.exec([[
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
    local result, nrows
    if kind and kind ~= "" then
        result, nrows = Base.query([[
            SELECT kind, name, aliases, role, description, gender, occupation, updated_at
            FROM xray_entities
            WHERE source_id=? AND stable_id=? AND kind=?
            ORDER BY name COLLATE NOCASE ASC;
        ]], source_id, stable_id, kind)
    else
        result, nrows = Base.query([[
            SELECT kind, name, aliases, role, description, gender, occupation, updated_at
            FROM xray_entities
            WHERE source_id=? AND stable_id=?
            ORDER BY kind ASC, name COLLATE NOCASE ASC;
        ]], source_id, stable_id)
    end
    local out = {}
    if not result then return out end
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

--- 原子替换一本书的全部 X-Ray 实体。
---@param source_id string
---@param stable_id string
---@param entities table[]
---@param updated_at integer|nil
---@return boolean
function XrayDB.replace(source_id, stable_id, entities, updated_at)
    if not Base.exec("BEGIN IMMEDIATE;") then return false end
    local ok = Base.exec(
        [[DELETE FROM xray_entities WHERE source_id=? AND stable_id=?;]],
        source_id, stable_id
    ) ~= nil
    if ok then
        local stamp = tonumber(updated_at) or os.time()
        for index, entity in ipairs(entities) do
            if not XrayDB.upsert(source_id, stable_id, entity, stamp) then
                ok = false
                break
            end
        end
    end
    if ok and Base.exec("COMMIT;") then
        return true
    end
    Base.exec("ROLLBACK;")
    return false
end

return XrayDB
