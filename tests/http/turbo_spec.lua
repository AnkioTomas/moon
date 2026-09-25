--[[--
http.turbo：acquire/release 管泵；补丁经第一次 acquire 挂上。
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local UIManager = require("ui/uimanager")
local Turbo = require("http.turbo")

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

Stubs.flush()
