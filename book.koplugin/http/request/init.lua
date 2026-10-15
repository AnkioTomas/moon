--[[--
HTTP 请求原语（Turbo，非阻塞，唯一网络栈）：回调 + `{ cancel }`。

禁止 luasocket / socket.http / socketutil 超时路径。清缓存用 `http.cache` 的 `Cache.clear`。

@module koplugin.book.http.request
--]]

--- 可取消异步句柄（HTTP / Job / 源 Async）
---@class CancelHandle
---@field cancel fun(self: CancelHandle|nil)|fun()

--- get/post 第二参。url 是第一参，这里不准带。
---@class HttpRequestOpts
---@field headers table|nil
---@field timeout number|nil 请求超时秒
---@field connect_timeout number|nil 默认「网络超时」× 2/3（缺省 20）
---@field allow_redirects boolean|nil 显式 true 才跟 301/302
---@field auth_username string|nil
---@field auth_password string|nil
---@field accept string|nil get/post 默认 Accept
---@field content_type string|nil POST body 的 Content-Type
---@field on_progress fun(bytes: number, total: number|nil)|nil 仅 download；total 取自 Content-Length
---@field max_bytes number|nil 仅 download；超限失败
---@field cache_ttl number|nil 仅 GET；>0 时走 http.cache，秒（按 auth_username 隔离）

--- request / stream / download：一张表，必须带 url。
---@class HttpRequest : HttpRequestOpts
---@field url string
---@field method string|nil 默认 GET
---@field body string|nil
---@field proxy string|nil 仅 request：明文 HTTP 代理，覆盖 KOReader 设置（设置页实测用）

--- 未完成的请求句柄。cancel 幂等。
---@class HttpJob : CancelHandle

--- Request.stream 的增量回调。
---@class HttpStreamHandlers
---@field on_headers fun(code: any, headers: any)|nil
---@field on_data fun(chunk: string)|nil
---@field on_done fun(err: any)|nil err 为 nil 表示收完

local Cache = require("http.cache")
local Fetch = require("http.request.fetch")
local Header = require("http.request.header")
local Stream = require("http.request.stream")
local Turbo = require("http.turbo")
local logger = require("utils.log")
local T = require("ffi/util").template
local _ = require("gettext")

---@class Request
local Request = {}

--- HTTP 2xx（含 WebDAV 207）
Request.ok = Fetch.ok
--- 流式 HTTP：body 到达即 on_data，结束时 on_done(err)。
Request.stream = Stream.open

--- 读单个响应头（大小写不敏感）。兼容 Turbo HTTPHeaders 与普通 table。
---@param res table|nil
---@param name string
function Request.header(res, name)
    local headers = res and res.headers
    if not headers then
        return nil
    end
    if type(headers.get) == "function" then
        return (headers:get(name, true))
    end
    return Fetch.getHeader(headers, name)
end

--- 读同名响应头的全部值（大小写不敏感），总返回数组。
--- Turbo HTTPHeaders 直接遍历 _fields；普通 table 的值可能是数组或合并后的一行。
--- Set-Cookie 被合并成一行时按 Header.splitSetCookie 拆开。
---@param res table|nil
---@param name string
---@return string[]
function Request.headerAll(res, name)
    local headers = res and res.headers
    local raw = {}
    if type(headers) == "table" then
        local lower = name:lower()
        if type(headers._fields) == "table" then
            for _idx, field in ipairs(headers._fields) do
                if type(field) == "table" and type(field[1]) == "string" and field[1]:lower() == lower then
                    raw[#raw + 1] = field[2]
                end
            end
        elseif type(headers.get) == "function" then
            raw[1] = headers:get(name, true)
        else
            for key, value in pairs(headers) do
                if type(key) == "string" and key:lower() == lower then raw[#raw + 1] = value end
            end
        end
    end
    local out = {}
    local split = name:lower() == "set-cookie" and require("http.request.header").splitSetCookie
    local function add(value)
        if type(value) == "table" then
            for _idx, v in ipairs(value) do add(v) end
        elseif type(value) == "string" and value ~= "" then
            if split then
                for _idx, v in ipairs(split(value)) do out[#out + 1] = v end
            else
                out[#out + 1] = value
            end
        end
    end
    for _idx, value in ipairs(raw) do add(value) end
    return out
end

--- 非阻塞 HTTP。err 非 nil 时不要信任 res.body。
---@param opts HttpRequest
---@param cb fun(res: table|nil, err: any)
---@return HttpJob
function Request.request(opts, cb)
    local ctx, begin_err = Fetch.begin(opts, "book.http")
    if not ctx then
        return Fetch.fail("http callback", cb, nil, begin_err)
    end
    local state = { cancelled = false, done = false }

    --- 先回调再 release，连环请求不会把泵拆了又装；回调经 guard，抛错也一定 release。
    ---@param res table|nil
    local function settle(res, err)
        if state.done then
            return
        end
        state.done = true
        state.client = nil
        Fetch.log(ctx, err or (state.cancelled and "cancelled"), "status", res and res.code or "-",
            "bytes", res and type(res.body) == "string" and #res.body or 0)
        if not state.cancelled then
            Fetch.call("http callback", cb, res, err)
        end
        Turbo.release()
    end

    ctx.loop:add_callback(function()
        if state.cancelled then
            settle()
            return
        end
        local client, client_err = Turbo.client(opts.proxy)
        if not client then
            settle(nil, client_err)
            return
        end
        state.client = client
        local fetched, future = pcall(client.fetch, client, opts.url, Fetch.options(opts, 1))
        if not fetched then
            settle(nil, future)
            return
        end
        local res = coroutine.yield(future)
        settle(res, Fetch.responseError(res))
    end)

    return Fetch.job(state, function()
        Fetch.close(state.client)
        settle()
    end)
end

--- GET / POST 共用：成功 cb(body, nil, res)，失败 cb(nil, err, res)。
--- GET 且 cache_ttl>0 时先读 http.cache，命中只回 cb(body) 不触网；成功才写入。
---@param method string
---@param url string
---@param body string|nil
---@param opts HttpRequestOpts|nil
---@param cb fun(body: string|nil, err: any, res: table|nil)
---@return HttpJob
local function send(method, url, body, opts, cb)
    opts = opts or {}
    local cache_ttl = method == "GET" and opts.cache_ttl or 0
    local cache_key = cache_ttl > 0 and Cache.key(method, url, nil, opts.auth_username) or nil
    local headers = Header.forRequest(opts.headers, opts.accept)
    if method == "POST" and body ~= nil then
        headers["Content-Type"] = opts.content_type
            or headers["Content-Type"]
            or "application/x-www-form-urlencoded"
    end
    local req = { url = url, method = method, body = body, headers = headers }
    for key, value in pairs(opts) do
        if req[key] == nil then req[key] = value end
    end
    return Cache.fetch(cache_key, cache_ttl, function(done)
        return Request.request(req, function(res, err)
            if err then
                done(nil, err, res)
            elseif not Request.ok(res.code) then
                done(nil, T(_("HTTP %1"), tostring(res.code)), res)
            else
                done(res.body or "", nil, res)
            end
        end)
    end, cb)
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

--- 非阻塞下载：写入 dest.part，成功后原子改名为 dest。
--- 取消时 stream 必回 on_done("cancelled")，关文件 / 删 .part 都在那里收口。
---@param opts HttpRequest 可带 on_progress / max_bytes
---@param dest string
---@param cb fun(ok: boolean, err: any, res: table|nil)
---@return HttpJob
function Request.download(opts, dest, cb)
    local state = { cancelled = false }
    local tmp = dest .. ".part"
    local target = dest:match("([^/]+)$") or dest
    local max_bytes = opts.max_bytes
    local written, total = 0, nil
    local response = {}
    local stream_job, write_err
    logger.dbg("book.http download start", target, Fetch.safeUrl(opts.url))

    ---@param ok boolean
    ---@param res table|nil
    local function done(ok, err, res)
        if state.cancelled then return end
        logger.dbg("book.http download done", target, ok and "ok" or ("error=" .. tostring(err)))
        cb(ok, err, res)
    end

    local file, open_err = io.open(tmp, "wb")
    if not file then
        return Fetch.fail("http download", done, false, open_err)
    end

    --- 已注定失败（超限/写盘错）就立刻断流，不再白拉剩余 body；on_done 仍会收口。
    ---@param reason string
    local function abort(reason)
        write_err = reason
        if stream_job then stream_job:cancel() end
    end

    stream_job = Request.stream(opts, {
        on_headers = function(code, headers)
            response.code = code
            response.headers = headers
            total = tonumber((Request.header({ headers = headers }, "Content-Length")))
            if max_bytes and total and total > max_bytes then
                abort("download too large")
            end
        end,
        on_data = function(chunk)
            if write_err or not Request.ok(response.code) then return end
            if max_bytes and written + #chunk > max_bytes then
                abort("download too large")
                return
            end
            local ok, err = file:write(chunk)
            if not ok then
                abort(err)
                return
            end
            written = written + #chunk
            if opts.on_progress then opts.on_progress(written, total) end
        end,
        on_done = function(err)
            local closed, close_err = file:close()
            err = write_err or err or (not closed and close_err) or nil
            -- 连接中途断开时 turbo 未必报错：按 Content-Length 校验，半截包不落位（压缩传输时长度不可比）。
            if not err and total and written < total and not Request.header(response, "Content-Encoding") then
                err = "download incomplete: " .. written .. "/" .. total
            end
            local moved, rename_err
            if not err then moved, rename_err = os.rename(tmp, dest) end
            if not moved then
                os.remove(tmp)
                return done(false, err or rename_err, response)
            end
            done(true, nil, response)
        end,
    })

    return Fetch.job(state, function()
        logger.dbg("book.http download cancel", target)
        stream_job:cancel()
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
    return string.format("%d.%d.%d.%d", math.random(1, 223), math.random(0, 255),
        math.random(0, 255), math.random(1, 254))
end

return Request
