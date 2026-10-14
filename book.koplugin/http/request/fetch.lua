--[[--
一次 Turbo HTTPClient:fetch 的共用件（http.request / http.request.stream 用，不对外）。

@module koplugin.book.http.request.fetch
--]]

local NetworkMgr = require("ui/network/manager")
local Turbo = require("http.turbo")
local logger = require("utils.log")
local Perf = require("utils.perf")
local Text = require("utils.text")
local T = require("ffi/util").template
local _ = require("gettext")

local Fetch = {}

--- 发起前就失败的请求句柄（失败回调已推迟到下一 tick）。
Fetch.NOOP = { cancel = function() end }

--- 业务回调入口：turbo 协程里抛错只进 turbo 日志，而且会跳过之后的 Turbo.release()，泵永不拆。
---@param label string
---@param fn function
function Fetch.call(label, fn, ...)
    return require("ui.guard").call(label, fn, ...)
end

--- 发起前就失败时推迟回调：调用方常把返回的句柄存起来、在回调里清掉，同步回调会被随后的赋值覆盖。
---@param label string
---@param fn function
---@return HttpJob
function Fetch.fail(label, fn, ...)
    local n, args = select("#", ...), { ... }
    require("ui/uimanager"):nextTick(function()
        Fetch.call(label, fn, unpack(args, 1, n))
    end)
    return Fetch.NOOP
end

local seq = 0

--- 日志只保留 scheme/host/path；query、fragment、userinfo 可能带令牌，禁止落盘。
---@return string
function Fetch.safeUrl(url)
    local value = tostring(url or "")
    value = value:gsub("#.*$", ""):gsub("%?.*$", "")
    return (value:gsub("^(https?://)[^/@]+@", "%1"))
end

---@class HttpFetchCtx
---@field id integer 日志里追踪同一个请求
---@field tag string 日志前缀
---@field method string
---@field url string 已脱敏
---@field started_at number
---@field loop table 已占泵的自建 ioloop，结束时必须 Turbo.release()

--- 开一次请求：查网络、编号、记日志、占泵。失败返回 nil, err（未占泵，不要 release）。
--- 只看网卡状态：isOnline 会在 UI 线程同步解析 DNS，每个请求都卡一次界面。
--- 本机回环（如蓝牙守护进程接口）不走网卡，Wi-Fi 关着也要能连。
---@param opts HttpRequest
---@param tag string
---@return HttpFetchCtx|nil
---@return string|nil err
function Fetch.begin(opts, tag)
    if not opts.url:find("^http://127%.0%.0%.1[:/]") and not NetworkMgr:isConnected() then
        return nil, _("网络不可用，请先连接 Wi-Fi")
    end
    seq = seq + 1
    local ctx = { id = seq, tag = tag, method = opts.method or "GET", url = Fetch.safeUrl(opts.url), started_at = Perf.now() }
    logger.dbg(tag .. " start", ctx.id, ctx.method, ctx.url)
    local loop, err = Turbo.acquire()
    if not loop then
        logger.dbg(tag .. " skip", ctx.id, ctx.method, ctx.url, err)
        return nil, T(_("网络组件加载失败：%1"), tostring(err))
    end
    ctx.loop = loop
    return ctx
end

--- 收尾日志。
---@param ctx HttpFetchCtx
function Fetch.log(ctx, err, ...)
    logger.dbg(ctx.tag .. " done", ctx.id, ctx.method, ctx.url, "ms", Perf.elapsedMs(ctx.started_at),
        err and ("error=" .. tostring(err)) or "ok", ...)
end

--- HTTP 2xx（含 WebDAV 207）
---@return boolean
function Fetch.ok(code)
    local n = tonumber(code)
    return n ~= nil and n >= 200 and n < 300
end

--- 普通 table 头，大小写不敏感。
---@param values table|nil
---@param name string
function Fetch.getHeader(values, name)
    name = name:lower()
    for key, value in pairs(values or {}) do
        if type(key) == "string" and key:lower() == name then
            return value
        end
    end
end

--- Turbo HTTPResponse.error → 可读字符串；无 error 返回 nil。
---@param res table|nil
---@return string|nil
function Fetch.responseError(res)
    if not res then
        return "network request failed"
    end
    local err = res.error
    if type(err) == "table" then
        return err.message or err.code or "network request failed"
    end
    return err and tostring(err)
end

--- 写入 Turbo HTTPHeaders。已有键 set（Host/User-Agent 此时已存在），新键 add；
--- 跳过 Content-Length：turbo 在 on_headers 之后会自己补，再加会重复。
---@param headers any Turbo HTTPHeaders
---@param values table|false|nil
local function addHeaders(headers, values)
    for name, value in pairs(values or {}) do
        if type(name) == "string" and value ~= nil and name:lower() ~= "content-length" then
            local text = tostring(value)
            if headers:get(name, true) ~= nil then
                headers:set(name, text, true)
            else
                headers:add(name, text)
            end
        end
    end
end

--- 拼 turbo HTTPClient:fetch 的 kwargs。timeout_ratio 是未传 opts.timeout 时相对「网络超时」的倍率。
--- turbo 文档写了 auth_username/auth_password 但从未实现，Basic 头只能自己拼。
---@param opts HttpRequest
---@param timeout_ratio number
---@return table
function Fetch.options(opts, timeout_ratio)
    local user = opts.auth_username
    local auth = user and user ~= "" and {
        Authorization = "Basic " .. Text.base64Encode(user .. ":" .. (opts.auth_password or "")),
    }
    local user_agent = Fetch.getHeader(opts.headers, "User-Agent")
    -- 超时 = 「网络超时」× 倍率（调用方已换算的原样用），规则见 http/timeout.lua。
    local request_timeout, connect_timeout = require("http.timeout").resolve(opts, timeout_ratio)
    return {
        method = opts.method or "GET",
        body = opts.body,
        request_timeout = request_timeout,
        connect_timeout = connect_timeout,
        allow_redirects = opts.allow_redirects,
        user_agent = user_agent and tostring(user_agent),
        on_headers = function(headers)
            addHeaders(headers, opts.headers)
            addHeaders(headers, auth)
        end,
    }
end

--- 取消时先拆 turbo 的连接/请求超时和已入队回调，再关 iostream。
--- 只关 socket 的话，超时还挂在私有 ioloop 上，下一次泵补跑并打出错误；
--- 写完成回调已经进 _callbacks 时，下次泵会在已关闭的流上 read。
---@param client table|nil 还没建 client 时为 nil
function Fetch.close(client)
    if not client then
        return
    end
    local loop = client.io_loop
    if loop and loop.remove_timeout then
        if client.connect_timeout_ref then loop:remove_timeout(client.connect_timeout_ref) end
        if client.request_timeout_ref then loop:remove_timeout(client.request_timeout_ref) end
    end
    client.connect_timeout_ref, client.request_timeout_ref = nil, nil
    local stream = client.iostream
    if stream then
        for _idx, field in ipairs({ "_write_callback", "_write_callback_arg", "_read_callback",
            "_read_callback_arg", "_connect_callback", "_connect_callback_arg", "_connect_fail_callback",
            "_ssl_connect_callback", "_ssl_connect_callback_arg" }) do
            stream[field] = nil
        end
    end
    local queued = loop and loop._callbacks
    if type(queued) == "table" then
        for i = #queued, 1, -1 do
            local arg = queued[i][2]
            if arg == client or (stream and type(arg) == "table" and arg[1] == stream) then
                table.remove(queued, i)
            end
        end
    end
    if stream and not stream:closed() then
        pcall(stream.close, stream)
    end
end

--- 进行中的请求句柄。cancel 幂等。
---@param state { cancelled: boolean }
---@param on_cancel fun()
---@return HttpJob
function Fetch.job(state, on_cancel)
    return {
        cancel = function()
            if state.cancelled then
                return
            end
            state.cancelled = true
            on_cancel()
        end,
    }
end

return Fetch
