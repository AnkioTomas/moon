--[[--
Turbo ioloop：补丁 + 按需泵。

不接管 UIManager.looper。对外只有一对进出：

  Turbo.acquire() → loop|nil   -- 建 loop、打补丁、占泵
  Turbo.release()              -- 对账，归零拆泵
  Turbo.client() → client, turbo_or_err

@module koplugin.book.http.turbo
--]]

local UIManager = require("ui/uimanager")
local logger = require("utils.log")

---@class Turbo
local Turbo = {}

local loop, pump, inflight, patched = nil, nil, 0, false

------------------------------------------------------------------------
-- 补丁：SNI / 无系统 CA / LuaSocket 点号 connect_fail
------------------------------------------------------------------------

--- Cloudflare 等按 SNI 分流；官方 turbo 存了 hostname 却不发。
---@param crypto table turbo.crypto
local function patchSni(crypto)
    if type(crypto.ssl_do_handshake) ~= "function" then
        return
    end
    local orig = crypto.ssl_do_handshake
    crypto.ssl_do_handshake = function(stream)
        local sock = stream and stream._ssl
        if sock and not stream._sni_done and type(sock.sni) == "function" then
            stream._sni_done = true
            local host = stream._ssl_hostname
            if type(host) == "string" and not host:find(":") and not host:match("^[%d%.]+$") then
                pcall(sock.sni, sock, host)
            end
        end
        return orig(stream)
    end
end

-- LuaSocket connect 按主机名在 UI 线程同步 getaddrinfo，SSL 握手前还会再 connect 一次。
-- 设备上没有系统 DNS 缓存，10 路封面下载就是 20 次阻塞解析；这里按主机名缓存结果。
local DNS_TTL = 10 * 60
local dns = {}

--- 主机名换成缓存地址；IP 字面量原样返回，解析失败交回 connect 报真实错误。
---@param host string
---@return string
local function resolve(host)
    if host:match("^[%d%.]+$") or host:find(":", 1, true) then
        return host
    end
    local now = os.time()
    local hit = dns[host]
    if hit and hit.expires > now then
        return hit.addr
    end
    local list = require("socket").dns.getaddrinfo(host)
    local addr = list and list[1] and list[1].addr
    if not addr then
        return host
    end
    dns[host] = { addr = addr, expires = now + DNS_TTL }
    return addr
end

--- `self._handle_connect_fail(err)` 点号调用会把 self 变成错误字符串。
--- 同时把主机名解析收口到 resolve。
local function patchConnectFail()
    local ok, iostream = pcall(require, "turbo.iostream")
    local IOStream = ok and iostream and iostream.IOStream
    if type(IOStream) ~= "table" or type(IOStream.connect) ~= "function" then
        return
    end
    if IOStream._book_connect_fail_patched then
        return
    end
    local orig_connect, orig_fail = IOStream.connect, IOStream._handle_connect_fail
    if type(orig_fail) ~= "function" then
        return
    end
    IOStream.connect = function(self, address, port, family, callback, fail_callback, arg)
        self._handle_connect_fail = function(first, second)
            if type(first) ~= "table" then
                return orig_fail(self, first)
            end
            return orig_fail(first, second)
        end
        return orig_connect(self, resolve(address), port, family, callback, fail_callback, arg)
    end
    IOStream._book_connect_fail_patched = true
end

--- 所有连接失败（同步/异步、HTTP/HTTPS）最终都汇到 HTTPClient:_handle_connect_fail，
--- 在这里丢弃该主机的 DNS 缓存，坏 IP 不会卡满 TTL。
--- LuaSocket 异步 connect 失败回调是 (client, -1, err)，官方只取第二参，提示成「Could not connect: -1」。
local function patchClientConnectFail()
    local ok, turbo = pcall(require, "turbo")
    local HTTPClient = ok and turbo.async and turbo.async.HTTPClient
    if type(HTTPClient) ~= "table" or type(HTTPClient._handle_connect_fail) ~= "function" then
        return
    end
    if HTTPClient._book_connect_fail_patched then
        return
    end
    local orig = HTTPClient._handle_connect_fail
    HTTPClient._handle_connect_fail = function(self, rc, err)
        dns[self.hostname] = nil
        if rc == -1 and err ~= nil then
            rc = err
        end
        return orig(self, rc)
    end
    HTTPClient._book_connect_fail_patched = true
end

--- buffer:len() / 已读字节是 FFI int64。stream 的增量路径会 math.min，cdata 直接炸。
local function patchReadSize()
    local ok, iostream = pcall(require, "turbo.iostream")
    local IOStream = ok and iostream and iostream.IOStream
    if type(IOStream) ~= "table" or type(IOStream._read_from_buffer) ~= "function" then
        return
    end
    if IOStream._book_read_size_patched then
        return
    end
    local orig = IOStream._read_from_buffer
    IOStream._read_from_buffer = function(self)
        self._read_buffer_size = tonumber(self._read_buffer_size) or 0
        self._read_bytes = tonumber(self._read_bytes)
        return orig(self)
    end
    IOStream._book_read_size_patched = true
end

--- 会话内只打一次。忽略校验时不加载系统 CA（macOS 上默认 cafile 不存在会炸）。
local function patch()
    if patched then
        return
    end
    patched = true
    local ok, crypto = pcall(require, "turbo.crypto")
    if ok then
        patchSni(crypto)
        if type(crypto.ssl_create_client_context) == "function" then
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
                    options = { "all" },
                })
                if not ctx then
                    return -1, err
                end
                return 0, ctx
            end
        end
    end
    patchConnectFail()
    patchClientConnectFail()
    patchReadSize()
end

------------------------------------------------------------------------
-- 泵：复制 start() 一拍，poll=0。禁止 start()。
------------------------------------------------------------------------

--- 推进自建 ioloop 一拍：协程、回调、到期 timeout，poll 超时 0。
---@param target table
local function pumpOnce(target)
    local ok, err = pcall(function()
        local co_cbs = target._co_cbs
        if type(co_cbs) == "table" and #co_cbs > 0 then
            target._co_cbs = {}
            for i = 1, #co_cbs do
                if co_cbs[i] then
                    target:_resume_coroutine(co_cbs[i][1], co_cbs[i][2])
                end
            end
        end
        local callbacks = target._callbacks
        if type(callbacks) == "table" then
            target._callbacks = {}
            for i = 1, #callbacks do
                target:_run_callback(callbacks[i])
            end
        end
        local timeout_sz = target._timeouts_sz
        if type(timeout_sz) == "number" and timeout_sz > 0 then
            local util = require("turbo.util")
            local now = util.gettimemonotonic()
            local ran, i = 0, 0
            while ran ~= timeout_sz do
                local item = target._timeouts[i]
                if item ~= nil then
                    ran = ran + 1
                    if item:timed_out(now) == 0 then
                        target:_run_callback({ item:callback() })
                        target._timeouts[i] = nil
                        target._timeouts_sz = target._timeouts_sz - 1
                    end
                end
                i = i + 1
                if i > timeout_sz + 64 then
                    break
                end
            end
        end
        if type(target._event_poll) == "function" then
            target:_event_poll(0)
        end
    end)
    if not ok then
        logger.warn("book.http turbo pump", err)
    end
end

local function kick()
    if loop and inflight > 0 then
        pumpOnce(loop)
    end
end

--- 自建一只 IOLoop。禁止 ioloop.instance()：那是 UIManager.looper 的单例，
--- 一旦 start() 接管主循环，HID / 蓝牙翻页一起死。
---@return boolean
local function boot()
    TURBO_SSL = true -- luacheck: ignore
    __TURBO_USE_LUASOCKET__ = true -- luacheck: ignore
    if loop then
        patch()
        return true
    end
    local ok, turbo = pcall(require, "turbo")
    if not ok or type(turbo) ~= "table" or not turbo.ioloop then
        return false
    end
    local made, created = pcall(turbo.ioloop.IOLoop)
    if not made or type(created) ~= "table" then
        return false
    end
    loop = created
    patch()
    return true
end

--- 建自建 loop、打补丁、占泵（0→1 插 ZMQ + preventStandby）。
--- 失败返回 nil，调用方不要 release。
---@return table|nil ioloop
function Turbo.acquire()
    if not boot() then
        return nil
    end
    inflight = inflight + 1
    if inflight == 1 then
        if not pump then
            pump = {
                waitEvent = kick,
                stop = function() end,
            }
            UIManager:insertZMQ(pump)
        end
        UIManager:nextTick(kick)
        UIManager:preventStandby()
    end
    return loop
end

--- 对账。归零时拆泵并 allowStandby。多 acquire 必须成对 release。
function Turbo.release()
    if inflight == 0 then
        logger.warn("book.http pump release with no inflight")
        return
    end
    inflight = inflight - 1
    if inflight > 0 then
        return
    end
    UIManager:unschedule(kick)
    if pump then
        UIManager:removeZMQ(pump)
        pump = nil
    end
    UIManager:allowStandby()
end

--- 新建 HTTPClient（verify_ca=false），并关掉 turbo 的 success/warning 日志。
---@return table|nil client
---@return any turbo_or_err 成功为 turbo 模块；失败为错误
function Turbo.client()
    local ok, turbo = pcall(require, "turbo")
    if not ok then
        return nil, turbo
    end
    if turbo.log and turbo.log.categories then
        turbo.log.categories.success = false
        turbo.log.categories.warning = false
    end
    if not loop then
        return nil, "turbo loop not acquired"
    end
    local made, client = pcall(turbo.async.HTTPClient, { verify_ca = false }, loop)
    if not made then
        return nil, client
    end
    return client, turbo
end

return Turbo
