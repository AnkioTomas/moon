--[[--
HTTP 请求原语（Turbo，非阻塞，唯一网络栈）

禁止 luasocket / socket.http / socketutil 超时路径。
网络请求只有这一条：回调 + `{ cancel }`。

  Request.ensureTurbo() → boolean  -- 须在 UIManager:run 前调用
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

local UIManager = require("ui/uimanager")
local Header = require("http.header")
local Cache = require("http.cache")
local T = require("ffi/util").template
local _ = require("gettext")

local Request = {}

--- 并发请求期间拉长 UI 输入超时的引用计数。
local input_timeouts = 0

--- 写盘切片。太大单拍卡；太小 nextTick 开销高。
local WRITE_CHUNK = 64 * 1024

--- Turbo/LuaSec 即使 verify_ca=false 仍会加载默认 CA
--- （/etc/ssl/certs/ca-certificates.crt），macOS 等设备上不存在会直接炸。
local ssl_patched = false

------------------------------------------------------------------------
-- 内部
------------------------------------------------------------------------

--- Turbo 的 SSLIOStream 存了 _ssl_hostname 却从不设置 SNI；
--- Cloudflare 等按 SNI 分流的服务器直接拒绝无 SNI 握手（然后无限等 read，表现为超时）。
--- 握手前用 luasec 的 sni() 补上；IP 直连不发 SNI。
---@param crypto table turbo.crypto 模块
local function patchTurboSni(crypto)
    if type(crypto.ssl_do_handshake) ~= "function" then
        return
    end
    local orig = crypto.ssl_do_handshake
    crypto.ssl_do_handshake = function(stream)
        local sock = stream and stream._ssl
        if sock and not stream._sni_done and type(sock.sni) == "function" then
            stream._sni_done = true
            local host = stream._ssl_hostname
            -- IP 字面量（v4 纯数字点 / v6 含冒号）不是合法 SNI，只有域名才发
            if type(host) == "string" and not host:find(":") and not host:match("^[%d%.]+$") then
                pcall(sock.sni, sock, host)
            end
        end
        return orig(stream)
    end
end

--- 忽略校验时不传 cafile，避免「error loading CA locations」。
local function patchTurboSsl()
    if ssl_patched then
        return
    end
    ssl_patched = true
    local ok, crypto = pcall(require, "turbo.crypto")
    if not ok then
        return
    end
    patchTurboSni(crypto)
    if type(crypto.ssl_create_client_context) ~= "function" then
        return
    end
    local orig = crypto.ssl_create_client_context
    crypto.ssl_create_client_context = function(cert_file, prv_file, ca_cert_path, verify, sslv)
        if verify then
            return orig(cert_file, prv_file, ca_cert_path, verify, sslv)
        end
        local ssl = require("ssl")
        local ctx, err = ssl.newcontext({
            mode = "client",
            protocol = "sslv23",
            key = prv_file,
            certificate = cert_file,
            options = {"all"},
        })
        if not ctx then
            return -1, err
        end
        return 0, ctx
    end
end

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

--- Turbo appends these after on_headers; adding one in the callback duplicates it.
local TURBO_SKIP_HEADERS = {
    ["content-length"] = true,
}

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

---@param state { cancelled: boolean }
---@param on_cancel fun()|nil
---@return { cancel: fun() }
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
    return headers[name] or headers[name:lower()]
end

------------------------------------------------------------------------
-- Turbo ioloop
------------------------------------------------------------------------

--- 打开 Turbo ioloop（会话级）。必须在 UIManager:run() 进入主循环之前调用，
--- 否则主循环走 classic 路径，looper:add_callback 永远不会被泵。
--- KOReader 默认 DUSE_TURBO_LIB=false；本插件 HTTP 只走 Turbo。
---@return boolean
function Request.ensureTurbo()
    if UIManager.looper then
        return true
    end
    if G_defaults and not G_defaults:isTrue("DUSE_TURBO_LIB") then
        G_defaults:saveSetting("DUSE_TURBO_LIB", true)
    end
    UIManager:initLooper()
    return UIManager.looper ~= nil
end

------------------------------------------------------------------------
-- 请求
------------------------------------------------------------------------

--- 非阻塞 HTTP 请求。
---
--- opts：url, method, body, headers, timeout, connect_timeout,
---       auth_username, auth_password
--- cb(res, err)：err 非 nil 时不要信任 res.body。
---
---@param opts table
---@param cb fun(res: table|nil, err: any)
---@return { cancel: fun() }
function Request.request(opts, cb)
    opts = opts or {}
    local state = { cancelled = false }
    local user_agent = getHeader(opts.headers, "User-Agent")

    if not Request.ensureTurbo() then
        UIManager:nextTick(function()
            if not state.cancelled then
                cb(nil, "turbo looper unavailable")
            end
        end)
        return makeJob(state)
    end

    UIManager:setInputTimeout(1000)
    input_timeouts = input_timeouts + 1

    UIManager.looper:add_callback(function()
        local turbo = require("turbo")
        turbo.log.categories.success = false
        turbo.log.categories.warning = false
        patchTurboSsl()

        local client = turbo.async.HTTPClient({ verify_ca = false })
        local res = coroutine.yield(client:fetch(opts.url, {
            method = opts.method,
            body = opts.body,
            request_timeout = opts.timeout or 30,
            connect_timeout = opts.connect_timeout or 10,
            -- 显式 true 才跟随 301/302（turbo 对 307/308 本来就不跟）；默认不跟随
            allow_redirects = opts.allow_redirects,
            auth_username = opts.auth_username,
            auth_password = opts.auth_password,
            user_agent = user_agent and tostring(user_agent) or nil,
            on_headers = function(headers)
                addHeaders(headers, opts.headers)
            end,
        }))

        input_timeouts = input_timeouts - 1
        if input_timeouts == 0 then
            UIManager:resetInputTimeout()
        end

        if not state.cancelled then
            cb(res, responseError(res))
        end
    end)

    return makeJob(state)
end

--- GET；成功 cb(body, nil, res)，失败 cb(nil, err, res)。
---@param url string
---@param opts table|nil
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return { cancel: fun() }
function Request.get(url, opts, cb)
    opts = opts or {}
    return Request.request({
        url = url,
        method = "GET",
        headers = Header.forRequest(opts.headers, opts.accept),
        timeout = opts.timeout or opts.block_timeout or 30,
        connect_timeout = opts.connect_timeout or 10,
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

--- POST；成功 cb(body, nil, res)，失败 cb(nil, err, res)。
---@param url string
---@param body string|nil
---@param opts table|nil
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return { cancel: fun() }
function Request.post(url, body, opts, cb)
    opts = opts or {}
    local headers = Header.forRequest(opts.headers, opts.accept)
    if body ~= nil then
        body = tostring(body)
        headers["Content-Type"] = opts.content_type
            or headers["Content-Type"]
            or "application/x-www-form-urlencoded"
    end
    return Request.request({
        url = url,
        method = "POST",
        body = body,
        headers = headers,
        timeout = opts.timeout or opts.block_timeout or 30,
        connect_timeout = opts.connect_timeout or 10,
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

--- 流式 HTTP：body 字节到达即 on_data，结束时 on_done(err)。
--- 用于 SSE / chunked；仍走 Turbo，不引入第二网络栈。
---
--- opts：同 request（url/method/body/headers/timeout/…）
--- handlers：
---   on_headers(code, headers) 可选
---   on_data(chunk) 原始 body 增量
---   on_done(err) err 为 nil 表示成功收完
---
---@param opts table
---@param handlers { on_headers?: fun(code: any, headers: any), on_data?: fun(chunk: string), on_done?: fun(err: any) }
---@return { cancel: fun() }
function Request.stream(opts, handlers)
    opts = opts or {}
    handlers = handlers or {}
    local state = { cancelled = false, done = false, client = nil }
    local user_agent = getHeader(opts.headers, "User-Agent")

    --- 收束流：只回调一次 on_done，并归还此前占用的输入超时计数。
    --- 计数归零才 resetInputTimeout，避免并发流互相把对方的 1s 轮询关掉。
    ---@param err any nil 表示正常收完
    local function finish(err)
        if state.done then
            return
        end
        state.done = true
        input_timeouts = input_timeouts - 1
        if input_timeouts == 0 then
            UIManager:resetInputTimeout()
        end
        if handlers.on_done then
            handlers.on_done(err)
        end
    end

    --- 把 body 增量丢给 on_data，已取消或已结束后一律丢弃。
    ---@param chunk any 非字符串或空串直接忽略
    local function emit(chunk)
        if state.cancelled or state.done then
            return
        end
        if type(chunk) == "string" and #chunk > 0 and handlers.on_data then
            handlers.on_data(chunk)
        end
    end

    if not Request.ensureTurbo() then
        UIManager:nextTick(function()
            if state.done then
                return
            end
            state.done = true
            if handlers.on_done then
                handlers.on_done(state.cancelled and "cancelled" or "turbo looper unavailable")
            end
        end)
        return makeJob(state, function()
            if state.done then
                return
            end
            state.done = true
            if handlers.on_done then
                handlers.on_done("cancelled")
            end
        end)
    end

    UIManager:setInputTimeout(1000)
    input_timeouts = input_timeouts + 1

    UIManager.looper:add_callback(function()
        if state.cancelled then
            finish("cancelled")
            return
        end

        local turbo = require("turbo")
        turbo.log.categories.success = false
        turbo.log.categories.warning = false
        patchTurboSsl()

        local httputil = require("turbo.httputil")
        local buffer = require("turbo.structs.buffer")
        local client = turbo.async.HTTPClient({ verify_ca = false })
        state.client = client

        local HTTPClient = getmetatable(client)
        HTTPClient = HTTPClient and HTTPClient.__index or turbo.async.HTTPClient
        local orig_chunked = HTTPClient._chunked_data
        local orig_body = HTTPClient._handle_body
        local orig_finalize = HTTPClient._finalize_request

        client._chunked_data = function(self, data)
            if data and data:len() > 2 then
                emit(data:sub(1, data:len() - 2))
            end
            return orig_chunked(self, data)
        end

        client._handle_body = function(self, data)
            emit(data)
            return orig_body(self, data)
        end

        client._finalize_request = function(self)
            orig_finalize(self)
            if state.done or state.cancelled then
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
            if code == 101 then
                self:_finalize_request()
                return
            elseif 100 <= code and code < 200 then
                self.iostream:read_until_pattern("\r?\n\r?\n", self._handle_headers, self)
                return
            end

            if not state.cancelled and handlers.on_headers then
                handlers.on_headers(code, self.response_headers)
            end

            local content_length = self.response_headers:get("Content-Length", true)
            local transfer = self.response_headers:get("Transfer-Encoding", true)
            if transfer and tostring(transfer):lower() == "chunked" and self.kwargs.method ~= "HEAD" then
                self._chunked = true
                self._read_buffer = buffer()
                self.iostream:read_until("\r\n", self._handle_chunked_encoding, self)
                return
            end
            if content_length and tonumber(content_length) and tonumber(content_length) > 0
                and self.kwargs.method ~= "HEAD" then
                self.iostream:read_bytes(tonumber(content_length), self._handle_body, self)
                return
            end
            -- 无 Content-Length / 非 chunked：按连接关闭读（SSE 常见）
            if self.kwargs.method == "HEAD" then
                self:_finalize_request()
                return
            end
            self.iostream:read_until_close(function(self_, final_data)
                if final_data and #final_data > 0 then
                    -- streaming_callback 已推送过的部分可能重复；只补尚未发出的尾部
                    emit(final_data)
                end
                self_.payload = final_data or ""
                self_:_finalize_request()
            end, self, function(_, chunk)
                emit(chunk)
            end, self)
        end

        local res = coroutine.yield(client:fetch(opts.url, {
            method = opts.method or "GET",
            body = opts.body,
            request_timeout = opts.timeout or 180,
            connect_timeout = opts.connect_timeout or 10,
            allow_redirects = opts.allow_redirects,
            auth_username = opts.auth_username,
            auth_password = opts.auth_password,
            user_agent = user_agent and tostring(user_agent) or nil,
            on_headers = function(headers)
                addHeaders(headers, opts.headers)
            end,
        }))

        -- finalize 通常已调 finish；兜底：yield 返回但未 finalize 时仍收口
        if not state.done then
            finish(responseError(res))
        end
    end)

    return makeJob(state, function()
        local client = state.client
        if client and client.iostream and not client.iostream:closed() then
            pcall(function()
                client.iostream:close()
            end)
        end
        if not state.done then
            finish("cancelled")
        end
    end)
end

------------------------------------------------------------------------
-- 写盘 / 下载
------------------------------------------------------------------------

--- 把响应 body 按切片写入文件（不堵单拍 UI）。
---@param res table|nil
---@param dest string
---@param opts { on_progress: fun(bytes: number)|nil }|nil
---@param cb fun(ok: boolean, err: any)
---@return { cancel: fun() }
function Request.writeResponseToFile(res, dest, opts, cb)
    opts = opts or {}
    local state = { cancelled = false }
    local body = res and res.body

    if type(body) ~= "string" then
        UIManager:nextTick(function()
            if not state.cancelled then
                cb(false, "empty response")
            end
        end)
        return makeJob(state)
    end

    local file, open_err = io.open(dest, "wb")
    if not file then
        UIManager:nextTick(function()
            if not state.cancelled then
                cb(false, open_err or "cannot create file")
            end
        end)
        return makeJob(state)
    end

    local offset = 1
    local written = 0

    --- 关闭文件并回调结果；失败时删除半截文件，不留下损坏的 dest。
    --- 已取消的任务不回调（调用方已经不关心结果了），但清理照做。
    ---@param ok boolean
    ---@param reason any 失败原因
    local function finish(ok, reason)
        pcall(file.close, file)
        if not ok then
            pcall(os.remove, dest)
        end
        if not state.cancelled then
            cb(ok, reason)
        end
    end

    --- 每个 nextTick 写一片 WRITE_CHUNK，写完再排下一片。
    --- 分片是为了不在一次事件循环里卡住 UI；写满即 finish(true)。
    local function writeNext()
        if state.cancelled then
            finish(false, "cancelled")
            return
        end
        if offset > #body then
            finish(true)
            return
        end
        local chunk = body:sub(offset, offset + WRITE_CHUNK - 1)
        local ok, write_err = file:write(chunk)
        if not ok then
            finish(false, write_err or "write failed")
            return
        end
        offset = offset + #chunk
        written = written + #chunk
        if opts.on_progress then
            opts.on_progress(written)
        end
        UIManager:nextTick(writeNext)
    end

    UIManager:nextTick(writeNext)
    return makeJob(state)
end

--- 非阻塞下载：request → 校验 2xx → writeResponseToFile。
---@param opts table 同 request；可带 on_progress
---@param dest string
---@param cb fun(ok: boolean, err: any, res: table|nil)
---@return { cancel: fun() }
function Request.download(opts, dest, cb)
    local state = { cancelled = false }
    local request_job
    local write_job

    request_job = Request.request(opts, function(res, err)
        if state.cancelled then
            return
        end
        if err then
            cb(false, err, res)
            return
        end
        if not Request.ok(res and res.code) then
            cb(false, "HTTP " .. tostring(res and res.code), res)
            return
        end
        write_job = Request.writeResponseToFile(res, dest, {
            on_progress = opts and opts.on_progress,
        }, function(ok, write_err)
            if not state.cancelled then
                cb(ok, write_err, res)
            end
        end)
    end)

    return makeJob(state, function()
        if request_job then
            request_job.cancel()
        end
        if write_job then
            write_job.cancel()
        end
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
