--[[--
Book (moon) HTTP 客户端（Bearer Token）

只返回 wire；不做契约字段转换。
网络仅异步：Request.request / Request.download。

@module koplugin.book.source.moon.client
--]]

local socketurl = require("socket.url")
local JSON = require("json")
local logger = require("logger")
local Request = require("http.request")
local Cache = require("http.cache")
local _ = require("gettext")
local T = require("ffi/util").template

local Client = {}

--- 去掉 URL 末尾多余斜杠。
---@param url string|nil
---@return string
local function trim_slash(url)
    return (url or ""):gsub("/+$", "")
end

--- 将表编码为 application/x-www-form-urlencoded（键排序）。
---@param tbl table
---@return string
local function encode_form(tbl)
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = tostring(k) .. "=" .. socketurl.escape(tostring(tbl[k]))
    end
    return table.concat(parts, "&")
end

--- 构造 Moon HTTP 客户端。
---@param o { base_url: string|nil, token: string|nil }|table|nil
---@return MoonClient
function Client:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.base_url = trim_slash(o.base_url or "")
    o.token = o.token or ""
    return o
end

--- 是否已配置服务器与令牌。
---@return boolean
function Client:configured()
    return self.base_url ~= "" and self.token ~= ""
end

--- 拼接 API URL（含 query）。
---@param path string
---@param query table|nil
---@return string|nil, string|nil
function Client:_url(path, query)
    if not self:configured() then
        return nil, _("未配置服务器或令牌")
    end
    local url = self.base_url .. path
    if query and next(query) then
        url = url .. "?" .. encode_form(query)
    end
    return url
end

--- 把 filename 编成 WebDAV 封面路径（分段 percent-encode）。
---@param filename string|nil
---@return string
local function webdavPath(filename)
    filename = tostring(filename or ""):gsub("^/+", "")
    local parts = {}
    for seg in filename:gmatch("[^/]+") do
        local enc = seg:gsub("([^%w%-%._~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        parts[#parts + 1] = enc
    end
    return "/webdav/" .. table.concat(parts, "/")
end

--- 构造封面 HTTP 请求。
---@param filename string
---@return { url: string, headers: table }|nil, string|nil
function Client:coverRequest(filename)
    if not filename or filename == "" then
        return nil, _("无效文件名")
    end
    if not self:configured() then
        return nil, _("未配置服务器或令牌")
    end
    local req = {
        url = self.base_url .. webdavPath(filename),
        headers = {
            ["Authorization"] = "Bearer " .. self.token,
            ["Accept"] = "*/*",
            ["Connection"] = "close",
        },
    }
    return req
end

--- Nonblocking JSON request.
---@param method string
---@param path string
---@param opts table|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Client:_jsonAsync(method, path, opts, cb)
    opts = opts or {}
    local url, cfg_err = self:_url(path, opts.query)
    if not url then
        cb(nil, cfg_err)
        return nil
    end
    method = string.upper(method or "GET")
    local cache_ttl = tonumber(opts.cache_ttl) or 0
    local cache_key
    if method == "GET" and cache_ttl > 0 then
        cache_key = Cache.key(method, self.base_url .. path, opts.query)
    end

    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Connection"] = "keep-alive",
        ["Accept"] = "application/json",
    }
    local body
    if opts.body then
        local ok, encoded
        if opts.json then
            ok, encoded = pcall(JSON.encode, opts.body)
            if not ok or type(encoded) ~= "string" then
                cb(nil, _("JSON 编码失败"))
                return nil
            end
            headers["Content-Type"] = "application/json"
        else
            encoded = encode_form(opts.body)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        end
        body = encoded
    end

    local cancelled = false
    local cache_job
    local request_job

    local function doRequest()
        if cancelled then
            return
        end
        request_job = Request.request({
            url = url,
            method = method,
            headers = headers,
            body = body,
            timeout = 30,
        }, function(res, req_err)
            if cancelled then
                return
            end
            if req_err then
                logger.info("book HTTP request error:", path, req_err)
                cb(nil, req_err)
                return
            end
            local code = tonumber(res and res.code)
            if not code then
                cb(nil, T(_("请求失败: %1"), tostring(res and res.code)))
                return
            end
            local raw = res.body or ""
            if raw:sub(1, 3) == "\239\187\191" then
                raw = raw:sub(4)
            end
            local ok, data = pcall(JSON.decode, raw)
            if not ok or type(data) ~= "table" then
                cb(nil, T(_("响应不是 JSON (HTTP %1) %2"), tostring(code), (raw:gsub("%s+", " ")):sub(1, 120)))
                return
            end
            if code == 401 or data.code == 401 then
                cb(nil, data.msg or _("令牌无效或未登录"))
                return
            end
            if data.code and data.code ~= 200 then
                cb(nil, data.msg or T(_("错误码 %1"), tostring(data.code)))
                return
            end
            if cache_key then
                Cache.set(cache_key, data, cache_ttl)
            end
            cb(data)
        end)
    end

    if cache_key then
        cache_job = Cache.getAsync(cache_key, function(hit)
            if cancelled then
                return
            end
            if hit ~= nil then
                cb(hit)
                return
            end
            doRequest()
        end)
    else
        doRequest()
    end

    return {
        cancel = function()
            cancelled = true
            if cache_job then
                cache_job.cancel()
            end
            if request_job then
                request_job.cancel()
            end
        end,
    }
end

function Client:listBooksAsync(query, cb)
    return self:_jsonAsync("GET", "/index/book/list", {
        query = query or {},
        cache_ttl = 5 * 60,
    }, cb)
end

function Client:recentBooksAsync(limit, cb)
    return self:_jsonAsync("GET", "/index/book/recent", {
        query = { limit = limit or 8 },
        cache_ttl = 5 * 60,
    }, cb)
end

function Client:filtersAsync(cb)
    return self:_jsonAsync("GET", "/index/book/filters", { cache_ttl = 5 * 60 }, cb)
end

function Client:importReadingStatsAsync(body, cb)
    return self:_jsonAsync("POST", "/index/stats/import", { body = body or {}, json = true }, function(res, err)
        if res then
            Request.clearCache("/index/stats/insight")
        end
        cb(res, err)
    end)
end

function Client:syncAnnotationsAsync(body, cb)
    return self:_jsonAsync("POST", "/index/stats/annotations", {
        body = body or {},
        json = true,
    }, cb)
end

function Client:readingInsightAsync(cb)
    return self:_jsonAsync("GET", "/index/stats/insight", { cache_ttl = 30 * 60 }, cb)
end

function Client:getProgressAsync(filename, cb)
    return self:_jsonAsync("GET", "/index/book/progress", {
        query = { filename = filename },
    }, cb)
end

function Client:updateProgressAsync(body, cb)
    return self:_jsonAsync("POST", "/index/book/progressUpdate", { body = body or {} }, function(res, err)
        if res then
            Request.clearCache("/index/book/recent")
            Request.clearCache("/index/book/list")
        end
        cb(res, err)
    end)
end

--- Download without blocking the UI on LuaSocket.
---@param filename string
---@param temp_path string
---@param on_progress fun(bytes: number)|nil
---@param cb fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function Client:downloadBookAsync(filename, temp_path, on_progress, cb)
    local url, cfg_err = self:_url("/index/book/file", { filename = filename })
    if not url then
        cb(false, cfg_err)
        return nil
    end
    pcall(os.remove, temp_path)
    return Request.download({
        url = url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. self.token,
            ["Connection"] = "close",
            ["Accept"] = "*/*",
        },
        timeout = 120,
        on_progress = on_progress,
    }, temp_path, function(ok, err)
        if not ok then
            pcall(os.remove, temp_path)
            cb(false, err)
            return
        end
        local attr = require("libs/libkoreader-lfs").attributes(temp_path)
        if not attr or not attr.size or attr.size <= 0 then
            pcall(os.remove, temp_path)
            cb(false, _("下载文件为空"))
            return
        end
        cb(true)
    end)
end

return Client
