--[[--
HTTP 请求原语（luasocket）

  Request.send(req, timeout?, block_timeout?) → code, headers, err
  Request.get(url, opts?) → body, err
  Request.post(url, body, opts?) → body, err
  Request.ok(code) → boolean
  Request.clearCache(url_substr?) → 清 http.cache

GET JSON 缓存见 http.cache（由 moon.api 等按 URL+TTL 写入）。

@module koplugin.book.http.request
--]]

local http = require("socket.http")
pcall(require, "ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local Header = require("http.header")
local Cache = require("http.cache")
local _ = require("gettext")
local T = require("ffi/util").template

local Request = {}

--- 清空 HTTP URL 缓存（强制刷新）
---@param url_substr string|nil 只清包含该子串的键；nil=全部
function Request.clearCache(url_substr)
    Cache.clear(url_substr)
end

local function isTimeout(code)
    return code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE
end

--- 2xx（含 WebDAV 207）
---@param code any
---@return boolean
function Request.ok(code)
    local n = tonumber(code)
    return n ~= nil and n >= 200 and n < 300
end

--- 执行 luasocket 请求；统一超时 / pcall / 超时码。
---@param req table
---@param timeout number|nil 默认 10
---@param block_timeout number|nil 默认 30
---@return any code, table|nil headers, string|nil err
function Request.send(req, timeout, block_timeout)
    socketutil:set_timeout(timeout or 10, block_timeout or 30)
    local ok, code, headers = pcall(function()
        return socket.skip(1, http.request(req))
    end)
    socketutil:reset_timeout()
    if not ok then
        return nil, nil, tostring(code)
    end
    if isTimeout(code) then
        return nil, nil, _("网络超时")
    end
    return code, headers, nil
end

local function requestBody(method, url, body, opts)
    opts = opts or {}
    local chunks = {}
    local headers = Header.forRequest(opts.headers, opts.accept)
    local source
    if body ~= nil then
        body = tostring(body)
        headers["Content-Length"] = tostring(#body)
        if opts.content_type then
            headers["Content-Type"] = opts.content_type
        elseif not headers["Content-Type"] then
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        end
        source = ltn12.source.string(body)
    end
    local code, _headers, err = Request.send({
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(chunks),
        user = opts.user,
        password = opts.password,
    }, opts.timeout, opts.block_timeout)
    if err then
        return nil, err
    end
    if not Request.ok(code) then
        return nil, T(_("HTTP %1"), tostring(code))
    end
    return table.concat(chunks)
end

--- GET 响应体（字符串）
---@param url string
---@param opts { headers: table|nil, timeout: number|nil, block_timeout: number|nil, accept: string|nil, user: string|nil, password: string|nil }|nil
---@return string|nil body, string|nil err
function Request.get(url, opts)
    return requestBody("GET", url, nil, opts)
end

--- POST 响应体（字符串）
---@param url string
---@param body string|nil
---@param opts { headers: table|nil, content_type: string|nil, timeout: number|nil, block_timeout: number|nil, accept: string|nil, user: string|nil, password: string|nil }|nil
---@return string|nil body, string|nil err
function Request.post(url, body, opts)
    return requestBody("POST", url, body, opts)
end

return Request
