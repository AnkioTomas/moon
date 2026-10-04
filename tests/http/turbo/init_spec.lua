--[[--
http.turbo：acquire/release 管泵；补丁经第一次 acquire 挂上。
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local UIManager = require("ui/uimanager")
local Turbo = require("http.turbo")
local Proxy = require("http.proxy")

-- SNI / 点号 connect_fail 必须在第一次 acquire 时装上（补丁只打一次）。
do
    local client_fail_msgs = {}
    local HTTPClient = {}
    function HTTPClient:_handle_connect_fail(strerr)
        client_fail_msgs[#client_fail_msgs + 1] = "Could not connect: " .. tostring(strerr or "")
    end
    package.loaded["turbo"] = nil
    package.preload["turbo"] = function()
        return {
            log = { categories = {} },
            async = { HTTPClient = HTTPClient },
            ioloop = {
                IOLoop = function()
                    return { add_callback = function() end }
                end,
            },
        }
    end
    local handshake_calls = 0
    package.preload["turbo.crypto"] = function()
        return {
            ssl_create_client_context = function() return 0, {} end,
            ssl_do_handshake = function()
                handshake_calls = handshake_calls + 1
                return true
            end,
        }
    end
    local lookups = {}
    package.preload["socket"] = function()
        return { dns = { getaddrinfo = function(host)
            lookups[#lookups + 1] = host
            if host == "nx.invalid" then return nil, "host not found" end
            return { { family = "inet", addr = "10.0.0." .. #lookups } }
        end } }
    end
    package.preload["turbo.iostream"] = function()
        local IOStream = {}
        function IOStream:_handle_connect_fail(err)
            self.fail_self = self
            self.fail_err = err
        end
        function IOStream:connect(address)
            self.connected_to = address
            if self.should_fail then
                self._handle_connect_fail("Network is unreachable")
            end
        end
        function IOStream:_read_from_buffer()
            return self._read_buffer_size, self._read_bytes
        end
        return { IOStream = IOStream }
    end

    Assert.not_nil(Turbo.acquire())
    local crypto = require("turbo.crypto")
    local sni_hosts = {}
    local fake_sock = {
        sni = function(_, host)
            sni_hosts[#sni_hosts + 1] = host
        end,
    }
    local stream = { _ssl = fake_sock, _ssl_hostname = "api.ankio.net" }
    crypto.ssl_do_handshake(stream)
    crypto.ssl_do_handshake(stream)
    Assert.eq(#sni_hosts, 1)
    Assert.eq(sni_hosts[1], "api.ankio.net")
    crypto.ssl_do_handshake({ _ssl = fake_sock, _ssl_hostname = "1.2.3.4" })
    crypto.ssl_do_handshake({ _ssl = fake_sock, _ssl_hostname = "2001:db8::1" })
    Assert.eq(#sni_hosts, 1)
    Assert.eq(handshake_calls, 4)

    local iostream = require("turbo.iostream")
    local fail_stream = { should_fail = true }
    iostream.IOStream.connect(fail_stream, "example.com", 443)
    Assert.eq(fail_stream.fail_err, "Network is unreachable")
    Assert.eq(fail_stream.fail_self, fail_stream)

    -- 同一主机只在 UI 线程解析一次；IP 字面量不解析；连接失败丢缓存重解析。
    lookups = {}
    local a, b = {}, {}
    iostream.IOStream.connect(a, "cdn.example.com", 443)
    iostream.IOStream.connect(b, "cdn.example.com", 443)
    Assert.eq(#lookups, 1, "同主机第二次连接必须命中缓存")
    Assert.eq(a.connected_to, "10.0.0.1")
    Assert.eq(b.connected_to, "10.0.0.1")
    iostream.IOStream.connect({}, "1.2.3.4", 443)
    iostream.IOStream.connect({}, "2001:db8::1", 443)
    Assert.eq(#lookups, 1, "IP 字面量不得解析")
    -- 同步失败：iostream 经 run_callback 调 HTTPClient:_handle_connect_fail(client, err)
    HTTPClient._handle_connect_fail({ hostname = "cdn.example.com" }, "Network is unreachable")
    Assert.eq(client_fail_msgs[1], "Could not connect: Network is unreachable")
    local c = {}
    iostream.IOStream.connect(c, "cdn.example.com", 443)
    Assert.eq(#lookups, 2, "连接失败后必须重新解析")
    Assert.eq(c.connected_to, "10.0.0.2")
    -- LuaSocket 异步失败回调 (client, -1, err)：用真实错误，同样丢缓存
    HTTPClient._handle_connect_fail({ hostname = "cdn.example.com" }, -1, "connection refused")
    Assert.eq(client_fail_msgs[2], "Could not connect: connection refused")
    iostream.IOStream.connect({}, "cdn.example.com", 443)
    Assert.eq(#lookups, 3, "异步连接失败后也必须重新解析")
    HTTPClient._handle_connect_fail({ hostname = "cdn.example.com" }, -1)
    Assert.eq(client_fail_msgs[3], "Could not connect: -1", "无真实错误时保留原样")
    local nx = {}
    iostream.IOStream.connect(nx, "nx.invalid", 443)
    Assert.eq(nx.connected_to, "nx.invalid", "解析失败交回 connect 报真实错误")
    local ffi = require("ffi")
    local sized = {
        _read_buffer_size = ffi.new("int64_t", 16),
        _read_bytes = ffi.new("uint64_t", 32),
    }
    local got_size, got_bytes = iostream.IOStream._read_from_buffer(sized)
    Assert.eq(got_size, 16)
    Assert.eq(got_bytes, 32)
    Assert.eq(type(got_size), "number")
    Assert.eq(type(got_bytes), "number")
    Turbo.release()

    for _, name in ipairs({ "turbo", "turbo.crypto", "turbo.iostream", "socket" }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

-- 自建 loop：acquire 插泵，release 拔掉；官方 looper 存在也照样插泵。
do
    package.loaded["http.turbo"] = nil
    local Turbo = require("http.turbo")
    local zmq = { n = 0 }
    function UIManager:insertZMQ(handle)
        zmq.n = zmq.n + 1
        zmq.handle = handle
    end
    function UIManager:removeZMQ(handle)
        zmq.n = zmq.n - 1
        zmq.removed = handle
    end
    local standby = 0
    function UIManager:preventStandby()
        standby = standby + 1
    end
    function UIManager:allowStandby()
        standby = standby - 1
    end
    local loop
    package.loaded["turbo"] = nil
    package.preload["turbo"] = function()
        return {
            ioloop = {
                IOLoop = function()
                    loop = {
                        _callbacks = {},
                        _co_cbs = {},
                        _timeouts = {},
                        _timeouts_sz = 0,
                        add_callback = function(self, fn)
                            self._callbacks[#self._callbacks + 1] = { fn }
                        end,
                        _run_callback = function(_, cb)
                            cb[1]()
                        end,
                        _resume_coroutine = function() end,
                        _event_poll = function() end,
                    }
                    return loop
                end,
            },
        }
    end

    Assert.eq(Turbo.acquire(), loop)
    Assert.eq(zmq.n, 1)
    Assert.eq(standby, 1)
    local pumped = false
    loop._callbacks = { { function() pumped = true end } }
    zmq.handle.waitEvent()
    Assert.is_true(pumped)
    Turbo.release()
    Assert.eq(zmq.n, 0)
    Assert.eq(standby, 0)
    Assert.eq(zmq.removed, zmq.handle)

    Assert.eq(Turbo.acquire(), loop)
    Assert.eq(Turbo.acquire(), loop)
    Assert.eq(zmq.n, 1)
    Assert.eq(standby, 1)
    Turbo.release()
    Assert.eq(zmq.n, 1)
    Turbo.release()
    Assert.eq(zmq.n, 0)
    Assert.eq(standby, 0)

    UIManager.looper = { add_callback = function() end }
    local got = Turbo.acquire()
    Assert.eq(got, loop)
    Assert.is_true(got ~= UIManager.looper)
    Assert.eq(zmq.n, 1)
    Assert.eq(standby, 1)
    Turbo.release()
    Assert.eq(zmq.n, 0)
    Assert.eq(standby, 0)

    package.preload["turbo"] = nil
    package.loaded["turbo"] = nil
    function UIManager:insertZMQ() end
    function UIManager:removeZMQ() end
    function UIManager:preventStandby() end
    function UIManager:allowStandby() end
    UIManager.looper = nil
end

-- KOReader HTTP 代理（socket.http.PROXY）：只认明文 http://；只改客户端实例。
do
    package.loaded["http.turbo"] = nil
    local Turbo = require("http.turbo")
    local log = {}
    local function newStream()
        local Stream = {}
        Stream.__index = Stream
        function Stream:_do_ssl_handshake() log[#log + 1] = "handshake:" .. tostring(self._ssl_accepting) end
        function Stream:write(data, cb) self.written = data; cb() end
        function Stream:read_until_pattern(_pattern, cb, arg) self.on_reply = function(data) cb(arg, data) end end
        function Stream:close() self.closed_flag = true end
        return setmetatable({ _ssl_accepting = true, _connecting = true }, Stream)
    end
    local function newClient()
        local c = { kwargs = {} }
        function c._connect(self)
            log[#log + 1] = "connect:" .. self.hostname .. ":" .. self.port
            self.iostream = newStream()
            self.iostream._ssl_hostname = self.hostname
            return 0
        end
        function c._prepare_http_request(self)
            local headers = { added = {} }
            function headers:add(k, v) self.added[k] = v end
            if self.kwargs.on_headers then self.kwargs.on_headers(headers) end
            return { uri = self.path, headers = headers.added }
        end
        function c._handle_connect_fail() log[#log + 1] = "fail" end
        return c
    end
    package.loaded["turbo"] = nil
    package.preload["turbo"] = function()
        return {
            async = { HTTPClient = function() return newClient() end },
            ioloop = { IOLoop = function() return { add_callback = function() end } end },
        }
    end
    local http = {}
    package.loaded["socket.http"] = http
    Assert.not_nil(Turbo.acquire())

    -- 未设代理：方法原样
    local plain = Turbo.client()
    plain.schema, plain.hostname, plain.port = "https", "api.example.com", 443
    plain:_connect()
    Assert.eq(log[#log], "connect:api.example.com:443", "未设代理直连")

    -- 不支持的代理协议：直连
    http.PROXY = "https://secure.proxy:443"
    local direct = Turbo.client()
    direct.schema, direct.hostname, direct.port = "https", "api.example.com", 443
    direct:_connect()
    Assert.eq(log[#log], "connect:api.example.com:443", "https:// 代理不支持，直连")

    -- http 目标：连代理，请求行绝对 URI + 认证头，字段复原
    http.PROXY = "http://u:p@10.1.1.1:3128/"
    local c = Turbo.client()
    c.schema, c.hostname, c.port, c.path = "http", "example.com", 80, "/a?b=1"
    local on_headers_called = false
    c.kwargs.on_headers = function() on_headers_called = true end
    local req = c:_prepare_http_request()
    Assert.eq(req.uri, "http://example.com:80/a?b=1")
    Assert.eq(req.headers["Proxy-Authorization"], "Basic dTpw")
    Assert.is_true(on_headers_called, "调用方的 on_headers 照常执行")
    Assert.eq(c.path, "/a?b=1")
    c:_connect()
    Assert.eq(log[#log], "connect:10.1.1.1:3128")
    Assert.eq(c.hostname, "example.com", "连完复原目标主机")
    Assert.eq(c.port, 80)
    Assert.is_nil(rawget(c.iostream, "_do_ssl_handshake"), "http 目标不建隧道")

    -- https 目标：CONNECT 隧道，2xx 后恢复 TLS 状态并握手，SNI 用目标主机
    c.schema, c.hostname, c.port = "https", "api.example.com", 443
    Assert.eq(c:_prepare_http_request().uri, "/a?b=1", "https 请求行不改写")
    c:_connect()
    local s = c.iostream
    Assert.eq(log[#log], "connect:10.1.1.1:3128")
    Assert.eq(s._ssl_hostname, "api.example.com")
    s._connecting = false
    s:_do_ssl_handshake()
    Assert.eq(s.written, "CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n"
        .. "Proxy-Authorization: Basic dTpw\r\n\r\n")
    Assert.eq(s._ssl_accepting, false, "交换期间放开明文读写")
    s.on_reply("HTTP/1.1 200 Connection established\r\n\r\n")
    Assert.eq(log[#log], "handshake:true")
    Assert.is_nil(s.closed_flag)

    -- 代理拒绝：关流并按连接失败上报
    c:_connect()
    s = c.iostream
    local reported
    s._ssl_connect_errhandler = function(arg, rc, err) reported = { arg, rc, err } end
    s._ssl_connect_callback_arg = c
    s._connecting = false
    s:_do_ssl_handshake()
    s.on_reply("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
    Assert.is_true(s.closed_flag)
    Assert.eq(reported[1], c)
    Assert.eq(reported[2], -1)
    Assert.eq(reported[3], "proxy CONNECT 407")

    -- 连接未建立就来读事件：交回原握手，不发 CONNECT
    c:_connect()
    s = c.iostream
    s:_do_ssl_handshake()
    Assert.is_nil(s.written)
    Assert.eq(log[#log], "handshake:true")

    -- 无 scheme、无认证：缺省按 http；只有用户名不发认证
    http.PROXY = "proxy.lan:8080"
    c = Turbo.client()
    c.schema, c.hostname, c.port = "http", "example.com", 80
    Assert.is_nil(c:_prepare_http_request().headers["Proxy-Authorization"])
    c:_connect()
    Assert.eq(log[#log], "connect:proxy.lan:8080")
    http.PROXY = "http://u@proxy.lan"
    c = Turbo.client()
    c.schema, c.hostname, c.port = "http", "example.com", 80
    Assert.is_nil(c:_prepare_http_request().headers["Proxy-Authorization"])
    c:_connect()
    Assert.eq(log[#log], "connect:proxy.lan:80", "缺省端口 80")

    -- 单次请求覆盖 KOReader 设置（设置页实测未保存的地址）
    http.PROXY = nil
    c = Turbo.client("http://10.9.9.9:8888")
    c.schema, c.hostname, c.port = "http", "example.com", 80
    c:_connect()
    Assert.eq(log[#log], "connect:10.9.9.9:8888")

    -- 地址校验与规范化
    local p = Proxy.parse("  http://u:p@10.0.0.1:3128/ignored  ")
    Assert.eq(p.url, "http://u:p@10.0.0.1:3128")
    Assert.eq(p.auth, "Basic dTpw")
    Assert.eq(Proxy.parse("proxy.lan").url, "http://proxy.lan:80")
    Assert.eq(Proxy.parse("HTTP://proxy.lan:1").port, 1)
    for raw, msg in pairs({
        [""] = "代理地址为空",
        ["   "] = "代理地址为空",
        ["https://p:443"] = "只支持 http:// 代理",
        ["socks5://p:1080"] = "只支持 http:// 代理",
        ["http://:8080"] = "代理地址格式不正确",
        ["http://p:0"] = "代理地址格式不正确",
        ["http://p:65536"] = "代理地址格式不正确",
        ["http://p:abc"] = "代理地址格式不正确",
        ["http://a b:80"] = "代理地址格式不正确",
    }) do
        local got, err = Proxy.parse(raw)
        Assert.is_nil(got, raw)
        Assert.eq(err, msg, raw)
    end

    Turbo.release()
    package.loaded["socket.http"] = nil
    package.preload["turbo"] = nil
    package.loaded["turbo"] = nil
end

-- turbo 加载失败 / 缺 ioloop：acquire 返回原始原因，不占泵。
do
    package.loaded["http.turbo"] = nil
    package.loaded["turbo"] = nil
    package.preload["turbo"] = function() error("libtffi_wrap.so: cannot open shared object file") end
    local Fresh = require("http.turbo")
    local loop, err = Fresh.acquire()
    Assert.is_nil(loop)
    Assert.matches(err, "libtffi_wrap")

    package.loaded["turbo"] = nil
    package.preload["turbo"] = function() return {} end
    loop, err = Fresh.acquire()
    Assert.is_nil(loop)
    Assert.not_nil(err)

    package.preload["turbo"] = nil
    package.loaded["turbo"] = nil
    package.loaded["http.turbo"] = nil
end

Stubs.flush()
