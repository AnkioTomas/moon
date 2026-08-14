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
    local value, expires = Base.rowexec(string.format(
        [[SELECT value, expires FROM http WHERE key=%s LIMIT 1;]],
        Base.sqlQuote(key)
    ))
    if type(value) ~= "string" then
        return nil
    end
    return value, tonumber(expires) or 0
end

--- 写 HTTP 缓存行
---@param key string
---@param value_json string
---@param expires number
---@param source_id string|nil
---@return boolean
function HttpDB.set(key, value_json, expires, source_id)
    if type(key) ~= "string" or key == "" or type(value_json) ~= "string" then
        return false
    end
    Base.ensure()
    local sql = string.format(
        [[INSERT INTO http (key, value, expires, source_id) VALUES (%s,%s,%s,%s)
          ON CONFLICT(key) DO UPDATE SET
            value=excluded.value,
            expires=excluded.expires,
            source_id=COALESCE(excluded.source_id, http.source_id);]],
        Base.sqlQuote(key),
        Base.sqlQuote(value_json),
        Base.sqlQuote(tonumber(expires) or 0),
        Base.sqlQuote(source_id)
    )
    return Base.exec(sql) ~= nil
end

--- 删除一条 HTTP 缓存
---@param key string
---@return boolean
function HttpDB.delete(key)
    if type(key) ~= "string" or key == "" then
        return false
    end
    Base.ensure()
    return Base.exec(string.format(
        [[DELETE FROM http WHERE key=%s;]],
        Base.sqlQuote(key)
    )) ~= nil
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
    return Base.exec(string.format(
        [[DELETE FROM http WHERE key LIKE %s;]],
        Base.sqlQuote("%" .. pat .. "%")
    )) ~= nil
end

--- 删除已过期的 HTTP 缓存行
---@param now_ts number|nil
---@return boolean
function HttpDB.deleteExpired(now_ts)
    now_ts = tonumber(now_ts) or os.time()
    Base.ensure()
    return Base.exec(string.format(
        [[DELETE FROM http WHERE expires <= %d;]],
        now_ts
    )) ~= nil
end

return HttpDB
