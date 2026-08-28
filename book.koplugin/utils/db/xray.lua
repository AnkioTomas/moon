--[[--
X-Ray 书级实体。

@module koplugin.book.utils.db.xray
--]]

local Base = require("utils.db.base")

local XrayDB = {}

--- 校验书籍身份，通过则返回规范化的 source_id。
--- 返回 nil 让调用方直接拒绝这次读写，不带非法身份下到 SQL。
---@param source_id string|nil
---@param stable_id string|nil 必须是非空字符串
---@return string|nil source_id nil 表示身份非法
local function validBook(source_id, stable_id)
    source_id = Base.requireSourceId(source_id)
    if not source_id or type(stable_id) ~= "string" or stable_id == "" then
        return nil
    end
    return source_id
end

--- 写入或覆盖一个 X-Ray 实体。
---@param source_id string
---@param stable_id string
---@param kind string
---@param name string
---@param aliases_json string
---@param payload_json string
---@param updated_at integer|nil
---@return boolean
function XrayDB.upsertEntity(source_id, stable_id, kind, name, aliases_json, payload_json, updated_at)
    source_id = validBook(source_id, stable_id)
    if not source_id or type(kind) ~= "string" or kind == ""
        or type(name) ~= "string" or name == ""
        or type(aliases_json) ~= "string"
        or type(payload_json) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec([[
        INSERT INTO xray_entities
          (source_id, stable_id, kind, name, aliases_json, payload_json, updated_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(source_id, stable_id, kind, name) DO UPDATE SET
          aliases_json=excluded.aliases_json,
          payload_json=excluded.payload_json,
          updated_at=excluded.updated_at;
    ]], source_id, stable_id, kind, name, aliases_json, payload_json,
        tonumber(updated_at) or os.time()) ~= nil
end

--- 列出实体；kind 非空时按种类过滤。
---@param source_id string
---@param stable_id string
---@param kind string|nil
---@return table[]
function XrayDB.listEntities(source_id, stable_id, kind)
    source_id = validBook(source_id, stable_id)
    if not source_id then return {} end
    Base.ensure()
    local result, nrows
    if kind and kind ~= "" then
        result, nrows = Base.query([[
            SELECT kind, name, aliases_json, payload_json, updated_at
            FROM xray_entities
            WHERE source_id=? AND stable_id=? AND kind=?
            ORDER BY name COLLATE NOCASE ASC;
        ]], source_id, stable_id, kind)
    else
        result, nrows = Base.query([[
            SELECT kind, name, aliases_json, payload_json, updated_at
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
            aliases_json = result[3][i],
            payload_json = result[4][i],
            updated_at = tonumber(result[5][i]) or 0,
        }
    end
    return out
end

--- 删除一本书的全部 X-Ray 实体。
---@param source_id string
---@param stable_id string
---@return boolean
function XrayDB.deleteAllForBook(source_id, stable_id)
    source_id = validBook(source_id, stable_id)
    if not source_id then
        return false
    end
    Base.ensure()
    return Base.exec([[
        DELETE FROM xray_entities
        WHERE source_id=? AND stable_id=?;
    ]], source_id, stable_id) ~= nil
end

--- 删除指定实体。
---@param source_id string
---@param stable_id string
---@param kind string
---@param name string
---@return boolean
function XrayDB.deleteEntity(source_id, stable_id, kind, name)
    source_id = validBook(source_id, stable_id)
    if not source_id or type(kind) ~= "string" or type(name) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec([[
        DELETE FROM xray_entities
        WHERE source_id=? AND stable_id=? AND kind=? AND name=?;
    ]], source_id, stable_id, kind, name) ~= nil
end

return XrayDB
