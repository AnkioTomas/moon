--[[--
http 表：HTTP GET 响应缓存

@module koplugin.book.utils.db.http
--]]

local Base = require("utils.db.base")

local HttpDB = {}

--- 读 HTTP 缓存行（value_json, expires）
---@param key string
---@return string|nil, number|nil
function HttpDB.get(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    Base.ensure()
    local value, expires = Base.rowexec(
        [[SELECT value, expires FROM http WHERE key=? LIMIT 1;]],
        key
    )
    if type(value) ~= "string" then
        return nil
    end
    return value, tonumber(expires) or 0
end

--- 写 HTTP 缓存行
---@param key string
---@param value_json string
---@param expires number
---@return boolean
function HttpDB.set(key, value_json, expires)
    if type(key) ~= "string" or key == "" or type(value_json) ~= "string" then
        return false
    end
    Base.ensure()
    return Base.exec(
        [[INSERT INTO http (key, value, expires) VALUES (?,?,?)
          ON CONFLICT(key) DO UPDATE SET
            value=excluded.value,
            expires=excluded.expires;]],
        key,
        value_json,
        tonumber(expires) or 0
    ) ~= nil
end

--- 删除一条 HTTP 缓存
---@param key string
---@return boolean
function HttpDB.delete(key)
    if type(key) ~= "string" or key == "" then
        return false
    end
    Base.ensure()
    return Base.exec([[DELETE FROM http WHERE key=?;]], key) ~= nil
end

--- 清空 HTTP 缓存；有子串则只删 key 含该子串的行
---@param url_substr string|nil
---@return boolean
function HttpDB.clear(url_substr)
    Base.ensure()
    if type(url_substr) ~= "string" or url_substr == "" then
        return Base.exec([[DELETE FROM http;]]) ~= nil
    end
    local pat = url_substr:gsub("([%%_])", "%%%1")
    return Base.exec([[DELETE FROM http WHERE key LIKE ?;]], "%" .. pat .. "%") ~= nil
end

return HttpDB
