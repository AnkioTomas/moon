--[[--
HTTP 响应缓存（键 = METHOD + path + 规范化参数，TTL 秒）。

持久化在 http 表（JSON 文本 + expires），读写均在 UI 线程同步访问 SQLite；写操作后用 clear 失效。
读路径不写库：过期过滤在 SQL 里，淘汰放到写入时。

@module koplugin.book.http.cache
--]]

local DB = require("utils.db")
local JSON = require("json")
local logger = require("utils.log")
local UIManager = require("ui/uimanager")
local Text = require("utils.text")

local Cache = {}

DB.schema("http", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS http (
  key TEXT PRIMARY KEY, value TEXT NOT NULL, expires INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_http_expires ON http(expires);
]]) ~= nil
end)

--- 缓存键：`GET https://host/path?a=1&b=2`
--- query 表会规范化后拼到 path 上；url 自带的 `?…` 在提供 query 表时会被剥掉，避免双重查询。
---@param method string|nil 默认 GET
---@param url string path 或完整 URL（可含/不含 query）
---@param query table|nil 查询参数
---@param scope string|nil 认证用户等额外隔离维度；不得传入明文凭据
---@return string
function Cache.key(method, url, query, scope)
    method = string.upper(method or "GET")
    local key
    if type(query) == "table" and next(query) then
        key = method .. " " .. url:match("^([^?]*)") .. "?" .. Text.formEncode(query)
    else
        key = method .. " " .. url
    end
    if scope ~= nil then
        key = key .. " @" .. #scope .. ":" .. scope
    end
    return key
end

--- 读缓存；过期行不返回（由 write 淘汰），JSON 损坏则删行当未命中。
---@param key string
---@return any|nil
local function read(key)
    local value_json = DB.rowexec([[SELECT value FROM http WHERE key=? AND expires > ? LIMIT 1;]],
        key, os.time())
    if not value_json then
        return nil
    end
    local ok, value = pcall(JSON.decode, value_json)
    if ok then
        return value
    end
    DB.exec([[DELETE FROM http WHERE key=?;]], key)
end

--- 写缓存。缓存是尽力而为：编码或落库失败只记日志，不影响已成功的请求。
---@param key string
---@param ttl number 存活秒数
local function write(key, value, ttl)
    local ok, encoded = pcall(JSON.encode, value)
    if not ok then
        logger.warn("book.http.cache encode failed", key)
        return
    end
    DB.exec([[DELETE FROM http WHERE expires <= ?;]], os.time())
    local stored, err = DB.exec(
        [[INSERT INTO http (key, value, expires) VALUES (?,?,?)
          ON CONFLICT(key) DO UPDATE SET value=excluded.value, expires=excluded.expires;]],
        key, encoded, os.time() + ttl)
    if not stored then
        logger.warn("book.http cache set failed", key, err)
    end
end

--- 先读缓存，未命中再 load；load 回调 value 非 nil 且无 err 才写入。
--- key 为 nil 表示不走缓存，直接 load。读缓存推迟一拍，回调永远异步。
---@param key string|nil
---@param ttl number 存活秒数
---@param load fun(done: fun(value: any, err: any, ...)): { cancel: fun() }|nil
---@param cb fun(value: any, err: any, ...)
---@return { cancel: fun() }
function Cache.fetch(key, ttl, load, cb)
    if not key then
        return load(cb) or { cancel = function() end }
    end
    local cancelled, job = false, nil
    UIManager:nextTick(function()
        if cancelled then
            return
        end
        local hit = read(key)
        if hit ~= nil then
            cb(hit)
            return
        end
        job = load(function(value, err, ...)
            if value ~= nil and err == nil then
                write(key, value, ttl)
            end
            cb(value, err, ...)
        end)
    end)
    return { cancel = function()
        cancelled = true
        if job then
            job.cancel()
        end
    end }
end

--- 清空全部缓存；传 url_substr 则只失效 key 含该子串的条目。
---@param url_substr string|nil
function Cache.clear(url_substr)
    local ok, err
    if url_substr == nil or url_substr == "" then
        ok, err = DB.exec([[DELETE FROM http;]])
    else
        local pat = url_substr:gsub("([%%_\\])", "\\%1")
        ok, err = DB.exec([[DELETE FROM http WHERE key LIKE ? ESCAPE '\';]], "%" .. pat .. "%")
    end
    if not ok then
        logger.warn("book.http cache clear failed", url_substr, err)
    end
end

return Cache
