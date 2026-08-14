--[[--
Book (moon) HTTP 客户端（Bearer Token）

只返回 wire；不做契约字段转换。

@module koplugin.book.source.moon.client
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

--- JSON 请求。opts: query, body, json（body 用 application/json）, cache_ttl（秒）
---@param method string
---@param path string
---@param opts { query: table|nil, body: table|nil, json: boolean|nil, cache_ttl: number|nil }|nil
---@return table|nil, string|nil
function Client:_json(method, path, opts)
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
function Client:_raw(method, path, opts)
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

--- 探测 Moon 鉴权连通性。
---@return table|nil, string|nil
function Client:ping()
    return self:_json("GET", "/index/auth/ping")
end

--- 请求书库列表 wire。
---@param query table|nil
---@return table|nil, string|nil
function Client:listBooks(query)
    return self:_json("GET", "/index/book/list", {
        query = query or {},
        cache_ttl = 5 * 60,
    })
end

--- 请求最近阅读 wire。
---@param limit number|nil
---@return table|nil, string|nil
function Client:recentBooks(limit)
    return self:_json("GET", "/index/book/recent", {
        query = { limit = limit or 8 },
        cache_ttl = 5 * 60,
    })
end

--- 请求筛选条件 wire。
---@return table|nil, string|nil
function Client:filters()
    return self:_json("GET", "/index/book/filters", { cache_ttl = 5 * 60 })
end

--- 注册阅读设备。
---@param body table
---@return table|nil, string|nil
function Client:registerReadingDevice(body)
    return self:_json("POST", "/index/stats/device", { body = body or {}, json = true })
end

--- 导入阅读统计。
---@param body table
---@return table|nil, string|nil
function Client:importReadingStats(body)
    local res, err = self:_json("POST", "/index/stats/import", { body = body or {}, json = true })
    if res then
        Request.clearCache("/index/stats/insight")
    end
    return res, err
end

--- 请求阅读统计洞察 wire。
---@return table|nil, string|nil
function Client:readingInsight()
    return self:_json("GET", "/index/stats/insight", { cache_ttl = 30 * 60 })
end

--- 请求书籍进度 wire。
---@param filename string
---@return table|nil, string|nil
function Client:getProgress(filename)
    return self:_json("GET", "/index/book/progress", {
        query = { filename = filename },
    })
end

--- 上报书籍进度。
---@param body table
---@return table|nil, string|nil
function Client:updateProgress(body)
    local res, err = self:_json("POST", "/index/book/progressUpdate", { body = body or {} })
    if res then
        Request.clearCache("/index/book/recent")
        Request.clearCache("/index/book/list")
    end
    return res, err
end

--- HEAD 探测书籍文件大小。
---@param filename string
---@return number|nil
function Client:probeFileSize(filename)
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

--- 下载到 temp_path（通常为最终路径.part）；成功后由调用方原子改名。
---@param filename string
---@param temp_path string
---@param on_progress fun(bytes: number)|nil
---@return boolean|nil, string|nil
function Client:downloadBook(filename, temp_path, on_progress)
    os.remove(temp_path)
    local file, err = io.open(temp_path, "wb")
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
        os.remove(temp_path)
        return nil, msg
    end
    local attr = require("libs/libkoreader-lfs").attributes(temp_path)
    if not attr or not attr.size or attr.size <= 0 then
        os.remove(temp_path)
        return nil, _("下载文件为空")
    end
    return true
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
    logger.dbg("book.moon.client coverRequest", filename, req.url)
    return req
end

return Client
