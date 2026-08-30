--[[--
HTTP 表：HTTP GET 响应缓存。

@module koplugin.book.db.http
--]]

local Base = require("db.base")
local HttpDB = {}

--- 创建 HTTP 响应缓存表。
--- 仅在 Base.open() 的一次性 schema 初始化阶段调用。
---@return boolean 成功返回 true，SQL 失败返回 false
function HttpDB.ensureSchema()
    return Base.exec([[
CREATE TABLE IF NOT EXISTS http (
  key TEXT PRIMARY KEY, value TEXT NOT NULL, expires INTEGER NOT NULL
);
]]) ~= nil
end

--- 读取缓存条目；读取前批量删除所有已过期条目。
---@param key string 缓存键
---@return string|nil value_json 缓存的 JSON 文本
---@return number|nil expires Unix 秒级过期时间
function HttpDB.get(key)
    Base.ensure()
    Base.exec([[DELETE FROM http WHERE expires <= ?;]], os.time())
    local value, expires = Base.rowexec(
        [[SELECT value, expires FROM http WHERE key=? LIMIT 1;]],
        key
    )
    if type(value) ~= "string" then return nil end
    return value, tonumber(expires) or 0
end

--- 写入或覆盖缓存条目。
---@param key string 缓存键
---@param value_json string JSON 编码后的响应文本
---@param expires number Unix 秒级过期时间
---@return boolean 成功返回 true，SQL 失败返回 false
function HttpDB.set(key, value_json, expires)
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

--- 删除一个缓存条目。
---@param key string 缓存键
---@return boolean 成功返回 true，SQL 失败返回 false
function HttpDB.delete(key)
    Base.ensure()
    return Base.exec([[DELETE FROM http WHERE key=?;]], key) ~= nil
end

--- 清空缓存；传入子串时只删除键中包含该子串的条目。
---@param url_substr string|nil URL 子串；nil 或空字符串表示全部删除
---@return boolean
function HttpDB.clear(url_substr)
    Base.ensure()
    if type(url_substr) ~= "string" or url_substr == "" then
        return Base.exec([[DELETE FROM http;]]) ~= nil
    end
    local pat = url_substr:gsub("([%%_\\])", "\\%1")
    return Base.exec([[DELETE FROM http WHERE key LIKE ? ESCAPE '\';]], "%" .. pat .. "%") ~= nil
end

return HttpDB
