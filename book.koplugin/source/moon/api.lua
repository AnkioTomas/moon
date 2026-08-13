--[[--
Book (moon) HTTP 客户端（Bearer Token）

JSON：解码后返回 table（含 data.code 语义）；GET 可按完整 URL 走 http.cache。
二进制：download / HEAD 走 sink，不解析 JSON。
封面：只拼 WebDAV 请求描述，不发请求。
不做：契约字段转换、normalize*、业务语义。

@module koplugin.book.source.moon.api
--]]

local ltn12 = require("ltn12")
local socketurl = require("socket.url")
local socketutil = require("socketutil")
local JSON = require("json")
local logger = require("logger")
local Request = require("http.request")
local Cache = require("http.cache")
local Header = require("http.header")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = {}

local function trim_slash(url)
    return (url or ""):gsub("/+$", "")
end

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

---@param o { base_url: string|nil, token: string|nil }|table|nil
---@return MoonApi
function Api:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.base_url = trim_slash(o.base_url or "")
    o.token = o.token or ""
    return o
end

---@return boolean
function Api:configured()
    return self.base_url ~= "" and self.token ~= ""
end

---@param path string
---@param query table|nil
---@return string|nil, string|nil
function Api:_url(path, query)
    if not self:configured() then
        return nil, _("未配置服务器或令牌")
    end
    local url = self.base_url .. path
    if query and next(query) then
        url = url .. "?" .. encode_form(query)
    end
    return url
end

--- JSON 请求。opts: query, body, json（body 用 application/json）, cache_ttl（秒）
---@param method string
---@param path string
---@param opts { query: table|nil, body: table|nil, json: boolean|nil, cache_ttl: number|nil }|nil
---@return table|nil, string|nil
function Api:_json(method, path, opts)
    opts = opts or {}
    local url, cfg_err = self:_url(path, opts.query)
    if not url then
        return nil, cfg_err
    end

    method = string.upper(method or "GET")
    local cache_ttl = tonumber(opts.cache_ttl) or 0
    local cache_key
    if method == "GET" and cache_ttl > 0 then
        -- 键 = METHOD + path + 规范化 query（与 wire URL 的 pairs 顺序无关）
        cache_key = Cache.key(method, self.base_url .. path, opts.query)
        local hit = Cache.get(cache_key)
        if hit ~= nil then
            return hit
        end
    end

    local headers = Header.forRequest({
        ["Authorization"] = "Bearer " .. self.token,
        ["Connection"] = "keep-alive",
    }, "application/json")

    local source
    if opts.body then
        local body
        if opts.json then
            local ok, encoded = pcall(JSON.encode, opts.body)
            if not ok or type(encoded) ~= "string" then
                return nil, _("JSON 编码失败")
            end
            body = encoded
            headers["Content-Type"] = "application/json"
        else
            body = encode_form(opts.body)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        end
        headers["Content-Length"] = tostring(#body)
        source = ltn12.source.string(body)
    end

    local chunks = {}
    local code, _, req_err = Request.send({
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(chunks),
    }, 10, 30)

    if req_err then
        return nil, req_err
    end
    if not code or tonumber(code) == nil then
        logger.warn("book.api request failed", url, code)
        return nil, T(_("请求失败: %1"), tostring(code))
    end
    code = tonumber(code)

    local raw = table.concat(chunks)
    if raw:sub(1, 3) == "\239\187\191" then
        raw = raw:sub(4)
    end

    local data
    local jok, decoded = pcall(JSON.decode, raw)
    if jok and type(decoded) == "table" then
        data = decoded
    end

    if code == 401 or (data and data.code == 401) then
        return nil, (data and data.msg) or _("令牌无效或未登录")
    end
    if not data then
        local preview = (raw:gsub("%s+", " ")):sub(1, 120)
        logger.warn("book.api non-json", url, code, preview)
        return nil, T(_("响应不是 JSON (HTTP %1) %2"), tostring(code), preview)
    end
    if data.code and data.code ~= 200 then
        return nil, data.msg or T(_("错误码 %1"), tostring(data.code))
    end

    if cache_key then
        Cache.set(cache_key, data, cache_ttl)
    end
    return data
end

--- 二进制 / HEAD。opts: query, sink；成功返回 true + response headers
---@param method string
---@param path string
---@param opts { query: table|nil, sink: function }
---@return true|nil, table|string|nil
function Api:_raw(method, path, opts)
    local url, cfg_err = self:_url(path, opts.query)
    if not url then
        return nil, cfg_err
    end

    local code, headers_resp, req_err = Request.send({
        url = url,
        method = string.upper(method or "GET"),
        headers = Header.forRequest({
            ["Authorization"] = "Bearer " .. self.token,
            ["Connection"] = "close",
        }, "*/*"),
        sink = opts.sink,
    }, 10, 120)

    if req_err then
        return nil, req_err
    end
    if not code or tonumber(code) == nil then
        logger.warn("book.api request failed", url, code)
        return nil, T(_("请求失败: %1"), tostring(code))
    end
    if not Request.ok(code) then
        return nil, T(_("下载失败 HTTP %1"), tostring(code))
    end
    return true, headers_resp
end

---@return table|nil, string|nil
function Api:ping()
    return self:_json("GET", "/index/auth/ping")
end

---@param query table|nil
---@return table|nil, string|nil
function Api:listBooks(query)
    return self:_json("GET", "/index/book/list", {
        query = query or {},
        cache_ttl = 5 * 60,
    })
end

---@param limit number|nil
---@return table|nil, string|nil
function Api:recentBooks(limit)
    return self:_json("GET", "/index/book/recent", {
        query = { limit = limit or 8 },
        cache_ttl = 5 * 60,
    })
end

---@return table|nil, string|nil
function Api:filters()
    return self:_json("GET", "/index/book/filters", { cache_ttl = 5 * 60 })
end

---@param body table
---@return table|nil, string|nil
function Api:registerReadingDevice(body)
    return self:_json("POST", "/index/stats/device", { body = body or {}, json = true })
end

---@param body table
---@return table|nil, string|nil
function Api:importReadingStats(body)
    local res, err = self:_json("POST", "/index/stats/import", { body = body or {}, json = true })
    if res then
        Request.clearCache("/index/stats/insight")
    end
    return res, err
end

---@return table|nil, string|nil
function Api:readingInsight()
    return self:_json("GET", "/index/stats/insight", { cache_ttl = 30 * 60 })
end

---@param filename string
---@return table|nil, string|nil
function Api:getProgress(filename)
    return self:_json("GET", "/index/book/progress", {
        query = { filename = filename },
    })
end

---@param body table
---@return table|nil, string|nil
function Api:updateProgress(body)
    local res, err = self:_json("POST", "/index/book/progressUpdate", { body = body or {} })
    if res then
        Request.clearCache("/index/book/recent")
        Request.clearCache("/index/book/list")
    end
    return res, err
end

---@param filename string
---@return number|nil
function Api:probeFileSize(filename)
    if not filename or filename == "" then
        return nil
    end
    local ok, headers = self:_raw("HEAD", "/index/book/file", {
        query = { filename = filename },
        sink = ltn12.sink.null(),
    })
    if not ok or type(headers) ~= "table" then
        return nil
    end
    local n = tonumber(headers["content-length"] or headers["Content-Length"])
    if n and n > 0 then
        return n
    end
    return nil
end

---@param filename string
---@param dest_path string
---@param on_progress fun(bytes: number)|nil
---@return boolean|nil, string|nil
function Api:downloadBook(filename, dest_path, on_progress)
    local file, err = io.open(dest_path, "wb")
    if not file then
        return nil, err or _("无法创建本地文件")
    end
    local sink = ltn12.sink.file(file)
    if on_progress and socketutil.chainSinkWithProgressCallback then
        sink = socketutil.chainSinkWithProgressCallback(sink, on_progress)
    end
    local ok, msg = self:_raw("GET", "/index/book/file", {
        query = { filename = filename },
        sink = sink,
    })
    if not ok then
        os.remove(dest_path)
        return nil, msg
    end
    return true
end

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

---@param filename string
---@return { url: string, headers: table }|nil, string|nil
function Api:coverRequest(filename)
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
    logger.dbg("book.api coverRequest", filename, req.url)
    return req
end

return Api
