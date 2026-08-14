--[[--
HTTP 请求原语（Turbo，非阻塞，唯一网络栈）

禁止 luasocket / socket.http / socketutil 超时路径。
网络请求只有这一条：回调 + `{ cancel }`。

  Request.ensureTurbo() → boolean  -- 须在 UIManager:run 前调用
  Request.request(opts, cb) → { cancel }
  Request.get(url, opts, cb) → { cancel }
  Request.post(url, body, opts, cb) → { cancel }
  Request.download(opts, dest, cb) → { cancel }
  Request.ok(code) → boolean
  Request.header(res, name) → any
  Request.clearCache(url_substr?) → 清 http.cache

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

--- 忽略校验时不传 cafile，避免「error loading CA locations」。
local function patchTurboSsl()
    if ssl_patched then
        return
    end
    ssl_patched = true
    local ok, crypto = pcall(require, "turbo.crypto")
    if not ok or type(crypto.ssl_create_client_context) ~= "function" then
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

---@param headers any
---@param values table|nil
local function addHeaders(headers, values)
    for name, value in pairs(values or {}) do
        if type(name) == "string" and value ~= nil then
            headers:add(name, tostring(value))
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

    if not Request.ensureTurbo() then
        UIManager:nextTick(function()
            if not state.cancelled then
                cb(nil, "turbo looper unavailable")
            end
        end)
        return makeJob(state)
    end

    UIManager.looper:add_callback(function()
        UIManager:setInputTimeout()
        input_timeouts = input_timeouts + 1

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
            auth_username = opts.auth_username,
            auth_password = opts.auth_password,
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
        headers["Content-Length"] = tostring(#body)
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

    local function finish(ok, reason)
        pcall(file.close, file)
        if not ok then
            pcall(os.remove, dest)
        end
        if not state.cancelled then
            cb(ok, reason)
        end
    end

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

return Request
