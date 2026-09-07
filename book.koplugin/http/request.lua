--[[--
HTTP 请求原语（Turbo，非阻塞，唯一网络栈）

禁止 luasocket / socket.http / socketutil 超时路径。
网络请求只有这一条：回调 + `{ cancel }`。

  Request.request(opts, cb) → { cancel }
  Request.get(url, opts, cb) → { cancel }
  Request.post(url, body, opts, cb) → { cancel }
  Request.stream(opts, handlers) → { cancel }  -- 增量 body（SSE / chunked）
  Request.download(opts, dest, cb) → { cancel }
  Request.ok(code) → boolean
  Request.header(res, name) → any
  Request.clearCache(url_substr?) → 清 http.cache
  Request.randomUA() → string
  Request.randomIP() → string

@module koplugin.book.http.request
--]]

local Header = require("http.header")
local Cache = require("http.cache")
local Turbo = require("http.turbo")
local NetworkMgr = require("ui/network/manager")
local logger = require("utils.log")
local Perf = require("utils.perf")
local T = require("ffi/util").template
local _ = require("gettext")

---@class Request
local Request = {}

local request_seq = 0

--- 日志只保留 scheme/host/path；query、fragment、userinfo 可能带令牌，禁止落盘。
---@param url any
---@return string
local function safeUrl(url)
    local value = tostring(url or "")
    value = value:gsub("#.*$", ""):gsub("%?.*$", "")
    return (value:gsub("^(https?://)[^/@]+@", "%1"))
end

--- 日志用文件名，只要最后一段。
---@param path any
---@return string
local function fileName(path)
    return tostring(path or ""):match("([^/]+)$") or "<unknown>"
end

------------------------------------------------------------------------
-- 内部
------------------------------------------------------------------------

--- Turbo HTTPResponse.error → 可读字符串；无 error 返回 nil。
---@param res table|nil
---@return string|nil
local function responseError(res)
    if not res then
        return "network request failed"
    end
    if not res.error then
        return nil
    end
    if type(res.error) == "table" then
        return res.error.message or res.error.code or "network request failed"
    end
    return tostring(res.error)
end

--- turbo 在 on_headers 之后会自己补 Content-Length；回调里再加会重复。
local TURBO_SKIP_HEADERS = {
    ["content-length"] = true,
}

--- 普通 table 头，大小写不敏感。
---@param values table|nil
---@param name string
---@return any
local function getHeader(values, name)
    name = name:lower()
    for key, value in pairs(values or {}) do
        if type(key) == "string" and key:lower() == name then
            return value
        end
    end
end

--- 写入 Turbo HTTPHeaders。已有键 set，新键 add；跳过 Content-Length。
---@param headers any Turbo HTTPHeaders
---@param values table|nil
local function addHeaders(headers, values)
    for name, value in pairs(values or {}) do
        if type(name) == "string" and value ~= nil then
            local lower_name = name:lower()
            if not TURBO_SKIP_HEADERS[lower_name] then
                local text = tostring(value)
                -- Host/User-Agent already exist at this point. Replace those
                -- fields; add() is intentionally kept for new/multi-value headers.
                if headers:get(name, true) ~= nil then
                    headers:set(name, text, true)
                else
                    headers:add(name, text)
                end
            end
        end
    end
end

--- 已占泵或进行中的请求句柄。cancel 幂等。
---@param state { cancelled: boolean }
---@param on_cancel fun()|nil
---@return HttpJob
local function makeJob(state, on_cancel)
    return {
        cancel = function()
            if state.cancelled then
                return
            end
            state.cancelled = true
            if on_cancel then
                on_cancel()
            end
        end,
    }
end

--- 占泵。失败不要 release。
---@return table|nil ioloop
---@return string|nil err
local function open()
    local ioloop = Turbo.acquire()
    if not ioloop then
        return nil, "turbo looper unavailable"
    end
    return ioloop
end

--- 取消时关掉 iostream，打断未完成的 fetch。
---@param client table|nil
local function closeClient(client)
    if client and client.iostream and not client.iostream:closed() then
        pcall(function()
            client.iostream:close()
        end)
    end
end

--- 拼 turbo HTTPClient:fetch 的 kwargs。timeout 是未传 opts.timeout 时的默认秒。
---@param opts HttpRequestOpts
---@param user_agent any
---@param timeout number
---@return table
local function fetchOpts(opts, user_agent, timeout)
    return {
        method = opts.method or "GET",
        body = opts.body,
        request_timeout = opts.timeout or timeout,
        connect_timeout = opts.connect_timeout or 20,
        allow_redirects = opts.allow_redirects,
        auth_username = opts.auth_username,
        auth_password = opts.auth_password,
        user_agent = user_agent and tostring(user_agent) or nil,
        on_headers = function(headers)
            addHeaders(headers, opts.headers)
        end,
    }
end

------------------------------------------------------------------------
-- 缓存 / 判定 / 头
------------------------------------------------------------------------

--- 清空 HTTP URL 缓存（强制刷新）
---@param url_substr string|nil 只清包含该子串的键；nil=全部
function Request.clearCache(url_substr)
    Cache.clear(url_substr)
end

--- HTTP 2xx（含 WebDAV 207）
---@param code any
---@return boolean
function Request.ok(code)
    local n = tonumber(code)
    return n ~= nil and n >= 200 and n < 300
end

--- 读单个响应头。兼容 Turbo HTTPHeaders 与普通 table。
---@param res table|nil
---@param name string
---@return any
function Request.header(res, name)
    local headers = res and res.headers
    if not headers then
        return nil
    end
    if type(headers.get) == "function" then
        return headers:get(name, true) or headers:get(name)
    end
    return getHeader(headers, name)
end

------------------------------------------------------------------------
-- 请求
------------------------------------------------------------------------

--- 非阻塞 HTTP。err 非 nil 时不要信任 res.body。
---@param opts HttpRequestOpts
---@param cb fun(res: table|nil, err: any)
---@return HttpJob
function Request.request(opts, cb)
    if not NetworkMgr:isOnline() then
        cb(nil, _("网络不可用，请先连接 Wi-Fi"))
        return { cancel = function() end }
    end
    opts = opts or {}
    local state = { cancelled = false, done = false, client = nil }
    local user_agent = getHeader(opts.headers, "User-Agent")
    request_seq = request_seq + 1
    local request_id = request_seq
    local method = tostring(opts.method or "GET")
    local url = safeUrl(opts.url)
    local started_at = Perf.now()
    logger.dbg("book.http start", request_id, method, url)

    ---@param res table|nil
    ---@param err any
    local function deliver(res, err)
        logger.dbg("book.http done", request_id, method, url,
            "status", res and res.code or "-", "ms",
            Perf.elapsedMs(started_at),
            "bytes", res and type(res.body) == "string" and #res.body or 0,
            err and ("error=" .. tostring(err)) or "ok")
        cb(res, err)
    end

    local ioloop, err = open()
    if not ioloop then
        logger.dbg("book.http skip", request_id, method, url, err)
        deliver(nil, err)
        return { cancel = function() end }
    end

    --- 先回调再 release，连环请求不会把泵拆了又装。
    ---@param res table|nil
    ---@param err any
    local function settle(res, err)
        if state.done then
            return
        end
        state.done = true
        state.client = nil
        if not state.cancelled then
            deliver(res, err)
        end
        Turbo.release()
    end

    ioloop:add_callback(function()
        if state.cancelled then
            settle()
            return
        end
        local client, turbo = Turbo.client()
        if not client then
            settle(nil, turbo)
            return
        end
        state.client = client
        local fetched, future = pcall(client.fetch, client, opts.url, fetchOpts(opts, user_agent, 30))
        if not fetched then
            settle(nil, future)
            return
        end
        local res = coroutine.yield(future)
        settle(res, responseError(res))
    end)

    return makeJob(state, function()
        if state.done then
            return
        end
        logger.dbg("book.http cancel", request_id, method, url)
        closeClient(state.client)
        settle()
    end)
end

--- GET / POST 共用：成功 cb(body, nil, res)，失败 cb(nil, err, res)。
---@param method string
---@param url string
---@param body string|nil
---@param opts HttpRequestOpts|nil
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return HttpJob
local function send(method, url, body, opts, cb)
    if not NetworkMgr:isOnline() then
        cb(nil, _("网络不可用，请先连接 Wi-Fi"))
        return { cancel = function() end }
    end
    opts = opts or {}
    local headers = Header.forRequest(opts.headers, opts.accept)
    if method == "POST" and body ~= nil then
        body = tostring(body)
        headers["Content-Type"] = opts.content_type
            or headers["Content-Type"]
            or "application/x-www-form-urlencoded"
    end
    return Request.request({
        url = url,
        method = method,
        body = body,
        headers = headers,
        timeout = opts.timeout or opts.block_timeout or 30,
        connect_timeout = opts.connect_timeout or 10,
        allow_redirects = opts.allow_redirects,
        auth_username = opts.user or opts.auth_username,
        auth_password = opts.password or opts.auth_password,
    }, function(res, err)
        if err then
            cb(nil, err, res)
        elseif not Request.ok(res and res.code) then
            cb(nil, T(_("HTTP %1"), tostring(res and res.code)), res)
        else
            cb(res.body or "", nil, res)
        end
    end)
end

--- GET。成功 cb(body, nil, res)，失败 cb(nil, err, res)。
---@param url string
---@param opts HttpRequestOpts|nil
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return HttpJob
function Request.get(url, opts, cb)
    return send("GET", url, nil, opts, cb)
end

--- POST。成功 cb(body, nil, res)，失败 cb(nil, err, res)。
---@param url string
---@param body string|nil
---@param opts HttpRequestOpts|nil
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return HttpJob
function Request.post(url, body, opts, cb)
    return send("POST", url, body, opts, cb)
end

--- 流式 HTTP：body 到达即 on_data，结束时 on_done(err)。
--- 用于 SSE / chunked。官方 turbo 会把整段 body 攒内存，这里改读路径。
---@param opts HttpRequestOpts
---@param handlers HttpStreamHandlers|nil
---@return HttpJob
function Request.stream(opts, handlers)
    if not NetworkMgr:isOnline() then
        if handlers and handlers.on_done then
            handlers.on_done(_("网络不可用，请先连接 Wi-Fi"))
        end
        return { cancel = function() end }
    end
    opts = opts or {}
    handlers = handlers or {}
    local state = { cancelled = false, done = false, client = nil }
    local user_agent = getHeader(opts.headers, "User-Agent")
    request_seq = request_seq + 1
    local request_id = request_seq
    local method = tostring(opts.method or "GET")
    local url = safeUrl(opts.url)
    local started_at = Perf.now()
    local received = 0
    logger.dbg("book.http stream start", request_id, method, url)

    --- 收束流：只回调一次 on_done。on_done 后再 release，方便连环开流。
    ---@param err any nil 表示正常收完
    local function finish(err)
        if state.done then
            return
        end
        state.done = true
        state.client = nil
        logger.dbg("book.http stream done", request_id, method, url, "ms",
            Perf.elapsedMs(started_at),
            "bytes", received,
            err and ("error=" .. tostring(err)) or "ok")
        if handlers.on_done then
            handlers.on_done(err)
        end
        Turbo.release()
    end

    --- 把 body 增量丢给 on_data，已取消或已结束后一律丢弃。
    ---@param chunk any 非字符串或空串直接忽略
    local function emit(chunk)
        if state.cancelled or state.done then
            return
        end
        if type(chunk) == "string" and #chunk > 0 then
            received = received + #chunk
            if handlers.on_data then handlers.on_data(chunk) end
        end
    end

    local ioloop, err = open()
    if not ioloop then
        logger.dbg("book.http stream skip", request_id, method, url, err)
        if handlers.on_done then handlers.on_done(err) end
        return { cancel = function() end }
    end

    ioloop:add_callback(function()
        if state.cancelled then
            finish("cancelled")
            return
        end

        local client, turbo = Turbo.client()
        if not client then
            finish(turbo)
            return
        end
        local got_httputil, httputil = pcall(require, "turbo.httputil")
        local got_buffer, buffer = pcall(require, "turbo.structs.buffer")
        if not got_httputil or not got_buffer then
            finish(got_httputil and buffer or httputil)
            return
        end
        state.client = client

        -- 官方 turbo 把整段 body 攒在内存里，SSE/大文件会炸。
        -- 只改读路径：有长度走 iostream 增量回调，chunked 不入 _read_buffer，
        -- 无长度按连接关闭读。301/302 先收尾再跟下一跳。
        local orig_finalize = client._finalize_request
        if type(orig_finalize) ~= "function" then
            finish("unsupported Turbo HTTPClient")
            return
        end

        client._chunked_data = function(self, data)
            if data and data:len() > 2 then
                emit(data:sub(1, data:len() - 2))
            end
            self.iostream:read_until("\r\n", self._handle_chunked_encoding, self)
        end

        client._finalize_request = function(self)
            local redirect_before = self.redirect
            orig_finalize(self)
            if self.redirect ~= redirect_before or state.done or state.cancelled then
                return
            end
            local code = self.response_headers
                and self.response_headers.get_status_code
                and self.response_headers:get_status_code()
            local err
            if self.s_error then
                err = self.error_str or "network request failed"
            elseif not Request.ok(code) then
                err = T(_("HTTP %1"), tostring(code))
            end
            finish(err)
        end

        client._handle_headers = function(self, data)
            if not data then
                self:_throw_error(turbo.async.errors.NO_HEADERS,
                    "No data receive after connect. Expected HTTP headers.")
                return
            end
            local status, headers = xpcall(httputil.HTTPParser, function() end,
                data, httputil.hdr_t["HTTP_RESPONSE"])
            if status == false then
                self:_throw_error(turbo.async.errors.PARSE_ERROR_HEADERS,
                    "Could not parse HTTP response header")
                return
            end
            self.response_headers = headers
            local code = self.response_headers:get_status_code()
            if not state.cancelled and handlers.on_headers then
                handlers.on_headers(code, self.response_headers)
            end
            if opts.allow_redirects and (code == 301 or code == 302) then
                self:_finalize_request()
                return
            end
            local transfer = self.response_headers:get("Transfer-Encoding", true)
            if transfer and tostring(transfer):lower() == "chunked" then
                self._chunked = true
                self._read_buffer = buffer()
                self.iostream:read_until("\r\n", self._handle_chunked_encoding, self)
                return
            end
            -- get() 可能多返回值；第二值进 tonumber 会当成进制。
            local content_length = tonumber((self.response_headers:get("Content-Length", true)))
            if content_length and content_length > 0 then
                self.iostream:read_bytes(content_length, function(self_)
                    self_.payload = ""
                    self_:_finalize_request()
                end, self, emit)
                return
            end
            self.iostream:read_until_close(function(self_, final_data)
                emit(final_data)
                self_.payload = ""
                self_:_finalize_request()
            end, self, emit)
        end

        local fetched, future = pcall(client.fetch, client, opts.url, fetchOpts(opts, user_agent, 180))
        if not fetched then
            finish(future)
            return
        end
        local res = coroutine.yield(future)

        -- finalize 通常已调 finish；兜底：yield 返回但未 finalize 时仍收口
        if not state.done then
            finish(responseError(res))
        end
    end)

    return makeJob(state, function()
        closeClient(state.client)
        if not state.done then
            finish("cancelled")
        end
    end)
end

------------------------------------------------------------------------
-- 下载
------------------------------------------------------------------------

--- 非阻塞下载：写入 dest.part，成功后原子改名为 dest。
---@param opts HttpRequestOpts 可带 on_progress / max_bytes
---@param dest string
---@param cb fun(ok: boolean, err: any, res: table|nil)
---@return HttpJob
function Request.download(opts, dest, cb)
    if not NetworkMgr:isOnline() then
        cb(false, _("网络不可用，请先连接 Wi-Fi"))
        return { cancel = function() end }
    end
    local state = { cancelled = false }
    local stream_job
    local tmp = dest .. ".part"
    local target = fileName(dest)

    local file, open_err = io.open(tmp, "wb")
    local written = 0
    local response = {}
    local write_err
    logger.dbg("book.http download start", target, safeUrl(opts and opts.url))

    ---@param ok boolean
    ---@param err any
    ---@param res table|nil
    local function done(ok, err, res)
        if state.cancelled then return end
        logger.dbg("book.http download done", target,
            ok and "ok" or ("error=" .. tostring(err)))
        cb(ok, err, res)
    end

    if not file then
        done(false, open_err or "cannot create file")
        return { cancel = function() end }
    end

    stream_job = Request.stream(opts, {
        on_headers = function(code, headers)
            response.code = code
            response.headers = headers
            local max_bytes = tonumber(opts and opts.max_bytes)
            local content_length = headers and headers.get and headers:get("Content-Length", true)
            if max_bytes and tonumber(content_length) and tonumber(content_length) > max_bytes then
                write_err = "download too large"
            end
        end,
        on_data = function(chunk)
            if write_err or not Request.ok(response.code) then return end
            local max_bytes = tonumber(opts and opts.max_bytes)
            if max_bytes and written + #chunk > max_bytes then
                write_err = "download too large"
                return
            end
            local ok, err = file:write(chunk)
            if not ok then
                write_err = err or "write failed"
                return
            end
            written = written + #chunk
            if opts and opts.on_progress then opts.on_progress(written) end
        end,
        on_done = function(err)
            local pok, closed, close_err = pcall(function() return file:close() end)
            file = nil
            if not err and write_err then err = write_err end
            if not err and (not pok or not closed) then
                err = close_err or "close failed"
            end
            if err or not Request.ok(response.code) then
                pcall(os.remove, tmp)
                done(false, err or ("HTTP " .. tostring(response.code)), response)
                return
            end
            local moved, rename_err = os.rename(tmp, dest)
            if not moved then
                pcall(os.remove, tmp)
                done(false, rename_err or "rename failed", response)
                return
            end
            done(true, nil, response)
        end,
    })

    return makeJob(state, function()
        logger.dbg("book.http download cancel", target)
        if stream_job then stream_job.cancel() end
        if file then pcall(function() file:close() end); file = nil end
        pcall(os.remove, tmp)
    end)
end

--- 生成随机 User-Agent（刮削 / 伪装浏览器用）。
---@return string
function Request.randomUA()
    local uas = {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    }
    return uas[math.random(#uas)]
end

--- 生成随机 IP（X-Forwarded-For）。
---@return string
function Request.randomIP()
    return string.format("%d.%d.%d.%d",
        math.random(1, 223),
        math.random(0, 255),
        math.random(0, 255),
        math.random(1, 254)
    )
end

return Request
