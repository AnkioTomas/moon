--[[--
HTTP GET 响应缓存（键 = METHOD + path + 规范化 query，TTL 秒）。

持久化在 utils.db.http（JSON 文本 + expires）。
只存成功响应；调用方传入 ttl>0 才写入。
写操作后应 Request.clearCache() 或 Cache.clear() 失效。

读/写均经 Task 子进程碰库（主进程禁止 SQLite）。

@module koplugin.book.http.cache
--]]

local JSON = require("json")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local DbQueue = require("utils.db.queue")

local Cache = {}

--- 查询表 → 稳定 query string（键排序；不做 URL escape，仅作缓存键）
---@param query table|nil
---@return string 无前导 `?`；空表返回 ""
function Cache.queryString(query)
    if type(query) ~= "table" or not next(query) then
        return ""
    end
    local keys = {}
    for k in pairs(query) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(query[k])
    end
    return table.concat(parts, "&")
end

--- 缓存键：`GET https://host/path?a=1&b=2`
--- query 表会规范化后拼到 path 上；url 自带的 `?…` 在提供 query 表时会被剥掉，避免双重查询。
---@param method string|nil 默认 GET
---@param url string path 或完整 URL（可含/不含 query）
---@param query table|nil 查询参数
---@return string
function Cache.key(method, url, query)
    method = string.upper(tostring(method or "GET"))
    url = tostring(url or "")
    local qs = Cache.queryString(query)
    if qs ~= "" then
        local path = url:match("^([^?]*)") or url
        return method .. " " .. path .. "?" .. qs
    end
    return method .. " " .. url
end

--- 异步读取缓存；过期或 JSON 损坏则删行并 cb(nil)
---@param key string
---@param cb fun(value: any|nil)
---@return { cancel: fun() }
function Cache.getAsync(key, cb)
    if type(key) ~= "string" or key == "" then
        UIManager:nextTick(function()
            cb(nil)
        end)
        return { cancel = function() end }
    end

    local cancelled = false

    UIManager:nextTick(function()
        if cancelled then
            return
        end
        local HttpDB = require("utils.db.http")
        local value_json, expires = HttpDB.get(key)
        if value_json and (expires or 0) > os.time() then
            local ok, value = pcall(JSON.decode, value_json)
            if ok then
                cb(value)
                return
            end
            -- JSON 损坏，删除（写操作走队列）
            DbQueue.run(function()
                HttpDB.delete(key)
            end)
        elseif value_json then
            -- 过期，删除（写操作走队列）
            DbQueue.run(function()
                HttpDB.delete(key)
            end)
        end
        cb(nil)
    end)

    return {
        cancel = function()
            cancelled = true
        end,
    }
end

--- 写入缓存；ttl<=0 或 value 无法 JSON 编码则跳过（子进程落库，不堵 UI）
---@param key string
---@param value any
---@param ttl number 存活秒数
---@return nil
function Cache.set(key, value, ttl)
    ttl = tonumber(ttl) or 0
    if ttl <= 0 or value == nil or key == nil or key == "" then
        return
    end
    local ok, encoded = pcall(JSON.encode, value)
    if not ok or type(encoded) ~= "string" then
        logger.warn("book.http.cache encode failed", key)
        return
    end
    local expires = os.time() + ttl
    DbQueue.run(function()
        local HttpDB = require("utils.db.http")
        HttpDB.set(key, encoded, expires)
    end, {
        on_failed = function(err)
            logger.warn("book.http cache set failed", key, err)
        end,
    })
end

--- 清空全部缓存；传 url_substr 则只失效 key 含该子串的条目（子进程执行）
---@param url_substr string|nil
---@return nil
function Cache.clear(url_substr)
    DbQueue.run(function()
        local HttpDB = require("utils.db.http")
        HttpDB.clear(url_substr)
    end, {
        on_failed = function(err)
            logger.warn("book.http cache clear failed", url_substr, err)
        end,
    })
end

return Cache
