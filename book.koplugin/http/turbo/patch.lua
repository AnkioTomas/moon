--[[--
turbo 类补丁（会话内只打一次，由 http.turbo 建 loop 时调用）。主机名解析交给 http.dns（非阻塞 UDP）。

补丁：SNI、CA、connect_fail、int64、请求超时改空闲计时，以及 HTTPParser.get 的 strncasecmp 回退
（turbo 靠 io.popen("uname") 选平台绑定，Android 上 popen 失败留 nil，一读响应头就崩）。

@module koplugin.book.http.turbo.patch
--]]

local Patch = {}

local patched = false

local Dns = require("http.dns")
local logger = require("utils.log")

--- 另一族晚这么久再并行连（RFC 8305 的 Connection Attempt Delay）。IPv6 黑洞时不用等完整连接超时。
local ATTEMPT_DELAY = 0.25

---@param addr string
---@return boolean
local function is6(addr)
    return addr:find(":", 1, true) ~= nil
end

--- 本机能不能走 IPv6：UDP connect 只选路由、不发包，内核关了 IPv6 / 没地址 / 没路由都会立刻失败。
--- 不通还照连 AAAA，每个请求先失败再退回 IPv4，封面等批量请求同时十几条这样重试后
--- KOReader 几秒内段错误（Kindle 固件关 IPv6 时实测必现，开启 IPv6 后消失）；各平台通用。
--- 没有 udp6（离线测试的 socket 桩）无法判断，照常尝试。
---@return boolean
function Patch.hasIPv6()
    local socket = require("socket")
    if type(socket.udp6) ~= "function" then return true end
    local udp = socket.udp6()
    if not udp then return false end
    local routed = udp:setpeername("2001:4860:4860::8888", 53) == 1
    udp:close()
    return routed
end

--- 丢掉并行的那条连接。关流、成功、失败都走这里。
---@param stream table
local function dropAlt(stream)
    local alt = stream._book_alt
    if not alt then return end
    stream._book_alt = nil
    local UIManager = require("ui/uimanager")
    if alt.delay then UIManager:unschedule(alt.delay) end
    if alt.poll then UIManager:unschedule(alt.poll) end
    if alt.sock then alt.sock:close() end
end

--- 换上这一族的 socket。v4 且流上已经是 v4 socket 时不动（HTTPClient 建好的那只）。
--- 关掉流上现有 socket：已登记进 ioloop 的先摘掉，否则 ioloop 一直 poll 到已关的 socket，
--- 每拍报 "no handler for fd"，最终段错误（IPv6 失败退回 IPv4 时旧 socket 正是已登记状态）。
---@param stream table
---@param keep table|nil 不关的 socket
local function closeSocket(stream, keep)
    local old = stream.socket
    if not old or old == keep then return end
    if stream.io_loop then
        stream.io_loop:remove_handler(old)
        stream._state = nil
    end
    if old.close then old:close() end
end

---@param stream table
---@param addr string
---@return boolean
local function install(stream, addr)
    local want6 = is6(addr)
    if not want6 and stream.socket and not stream._book_v6 then return true end
    local socket = require("socket")
    local make = want6 and socket.tcp6 or socket.tcp
    -- 没有对应构造函数（离线测试的 socket 桩）：地址照旧交给原来的 connect。
    if type(make) ~= "function" then return true end
    local sock = make()
    if not sock then return false end
    sock:settimeout(0)
    pcall(sock.setoption, sock, "keepalive", true)
    closeSocket(stream, sock)
    stream.socket = sock
    stream._book_v6 = want6
    return true
end

--- 并行连接赢了：卸掉主连接，把赢的 socket 交给流，走 turbo 自己的「再 connect 一次看 already connected」。
---@param stream table
---@param on_ok function
---@param on_fail function
---@param arg any
local function promote(stream, on_ok, on_fail, arg)
    local alt = stream._book_alt
    if not alt or not alt.sock or not stream._connecting then return end
    if arg and arg.s_error then
        dropAlt(stream)
        return
    end
    local sock, addr, port = alt.sock, alt.addr, alt.port
    alt.sock = nil
    dropAlt(stream)
    closeSocket(stream, sock)
    stream.socket = sock
    stream.address = addr
    stream.port = port
    stream._book_v6 = is6(addr)
    stream._connecting = true
    stream._connect_callback = on_ok
    stream._connect_fail_callback = on_fail
    stream._connect_callback_arg = arg
    stream:_handle_connect()
end

--- 主连接发出去之后，晚 ATTEMPT_DELAY 再连另一个地址。先成功的用。
---@param stream table
---@param addr string
---@param port integer
---@param on_ok function
---@param on_fail function
---@param arg any
local function arm(stream, addr, port, on_ok, on_fail, arg)
    local socket = require("socket")
    if type(socket.select) ~= "function" then return end
    local make = is6(addr) and socket.tcp6 or socket.tcp
    if type(make) ~= "function" then return end
    local alt = { addr = addr, port = port }
    stream._book_alt = alt
    local UIManager = require("ui/uimanager")
    alt.delay = function()
        if stream._book_alt ~= alt or not stream._connecting or (arg and arg.s_error) then return end
        local sock = make()
        if not sock then return end
        sock:settimeout(0)
        pcall(sock.setoption, sock, "keepalive", true)
        local connected, err = sock:connect(addr, port)
        -- 非阻塞 connect：正在连是 timeout（LuaSocket）或 Operation already in progress。
        if not connected and err ~= "already connected" and err ~= "timeout"
            and err ~= "Operation already in progress" then
            sock:close()
            return
        end
        alt.sock = sock
        if connected or err == "already connected" then
            promote(stream, on_ok, on_fail, arg)
            return
        end
        alt.poll = function()
            if stream._book_alt ~= alt or not alt.sock then return end
            if not stream._connecting or (arg and arg.s_error) then
                dropAlt(stream)
                return
            end
            local _recv, writable = socket.select({}, { alt.sock }, 0)
            local ready = false
            if type(writable) == "table" then
                for _idx, candidate in ipairs(writable) do
                    if candidate == alt.sock then ready = true end
                end
            end
            if not ready then
                UIManager:scheduleIn(Dns.POLL, alt.poll)
                return
            end
            local connected_now, err_now = alt.sock:connect(addr, port)
            if connected_now or err_now == "already connected" then
                promote(stream, on_ok, on_fail, arg)
            else
                dropAlt(stream)
            end
        end
        UIManager:scheduleIn(Dns.POLL, alt.poll)
    end
    UIManager:scheduleIn(ATTEMPT_DELAY, alt.delay)
end

--- 包一层 target[name]。turbo 随 KOReader 版本变，方法不存在就跳过；
--- 类上记标记，插件重载（本模块重新加载、turbo 类还在）不会包两层。
---@param target table|nil
---@param name string
---@param make fun(orig: function): function
local function wrap(target, name, make)
    local mark = "_book_patched_" .. name
    if type(target) ~= "table" or type(target[name]) ~= "function" or target[mark] then
        return
    end
    target[name] = make(target[name])
    target[mark] = true
end

---@return table|nil
local function optional(name)
    local ok, mod = pcall(require, name)
    return ok and mod or nil
end

--- 会话内只打一次。
function Patch.apply()
    if patched then
        return
    end
    patched = true
    local crypto = optional("turbo.crypto")
    local iostream = optional("turbo.iostream")
    local turbo = optional("turbo")
    ---@type table|nil 补丁动的都是私有字段，类型桩里没有
    local IOStream = iostream and iostream.IOStream
    local HTTPClient = turbo and turbo.async and turbo.async.HTTPClient

    if rawget(_G, "__TURBO_USE_LUASOCKET__") then
        -- LuaSocket reports nonblocking partial writes as nil, "timeout", bytes_sent.
        -- Keep the stream alive and advance only by bytes actually sent.
        wrap(IOStream, "_handle_write_nonconst", function()
            local ffi = require("ffi")
            return function(self)
                local ptr = self._write_buffer:get()
                local write_size = math.min(self._write_buffer_size, 1024 * 128)
                local num_bytes, err, partial = self.socket:send(
                    ffi.string(ptr + self._write_buffer_offset, write_size))
                local sent = num_bytes
                if err == "timeout" then
                    sent = partial or 0
                elseif err then
                    logger.warn("book.http write failed", err)
                    self:close()
                    return
                end

                self._write_buffer_offset = self._write_buffer_offset + sent
                self._write_buffer_size = self._write_buffer_size - sent
                if self._write_buffer_size == 0 then
                    self._write_buffer:clear()
                    self._write_buffer_offset = 0
                    if self._write_callback then
                        local callback = self._write_callback
                        local arg = self._write_callback_arg
                        self._write_callback = nil
                        self._write_callback_arg = nil
                        self:_run_callback(callback, arg)
                    end
                end
            end
        end)
    end

    -- Cloudflare 等按 SNI 分流；官方 turbo 存了 hostname 却不发。
    wrap(crypto, "ssl_do_handshake", function(orig)
        return function(stream)
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
    end)

    -- 忽略校验时不加载系统 CA（macOS 上默认 cafile 不存在会炸）。
    wrap(crypto, "ssl_create_client_context", function(orig)
        return function(cert_file, prv_file, ca_cert_path, verify, sslv)
            if verify then
                return orig(cert_file, prv_file, ca_cert_path, verify, sslv)
            end
            local ctx, err = require("ssl").newcontext({
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
    end)

    -- 关流时收掉还在并行的另一族连接（取消、连接超时、连接失败都会关流）。
    wrap(IOStream, "close", function(orig)
        return function(self)
            dropAlt(self)
            return orig(self)
        end
    end)

    -- `self._handle_connect_fail(err)` 点号调用会把 self 变成错误字符串；主机名解析收口到 Dns.resolve（不阻塞）。
    -- HTTPClient 不看 connect 的返回值，只等 _handle_connect / _handle_connect_fail（外加自己的 connect 超时），
    -- 所以解析可以异步：先登记失败回调，地址到了再真正 connect。
    -- 两族都有时先连 IPv6，ATTEMPT_DELAY 后并行连 IPv4，谁先通谁。IPv6 立刻失败就马上换 IPv4，不等那 250ms。
    wrap(IOStream, "connect", function(orig)
        local orig_fail = IOStream._handle_connect_fail
        return function(self, address, port, family, callback, fail_callback, arg)
            self._handle_connect_fail = function(first, second)
                if type(first) ~= "table" then
                    return orig_fail(self, first)
                end
                return orig_fail(first, second)
            end
            self._connect_fail_callback, self._connect_callback_arg = fail_callback, arg
            self._connecting = true
            local function dial(list)
                local index = 1
                local go
                local function advance()
                    dropAlt(self)
                    if not list[index + 1] then return false end
                    index = index + 1
                    go()
                    return true
                end
                -- SSLIOStream 的异步连接失败不经 fail_callback，而是清空 errhandler / callback / arg 后直接调
                -- _ssl_connect_errhandler；截住它，还有下一个地址就放回这三样再退回去。
                local ssl_final = self._ssl_connect_errhandler
                local ssl_callback, ssl_arg = self._ssl_connect_callback, self._ssl_connect_callback_arg
                local function ssl_retry(...)
                    if list[index + 1] then
                        self._ssl_connect_errhandler = ssl_retry
                        self._ssl_connect_callback, self._ssl_connect_callback_arg = ssl_callback, ssl_arg
                        advance()
                        return
                    end
                    return ssl_final(...)
                end
                if ssl_final then self._ssl_connect_errhandler = ssl_retry end
                function go()
                    while list[index] and not install(self, list[index]) do index = index + 1 end
                    local addr = list[index]
                    if not addr then
                        if fail_callback then fail_callback(arg, "no address") end
                        return
                    end
                    local function on_ok(...)
                        dropAlt(self)
                        if arg and arg.s_error then return end
                        if callback then return callback(...) end
                    end
                    local function on_fail(...)
                        if advance() then return end
                        if fail_callback then return fail_callback(...) end
                    end
                    local fallback = list[index + 1]
                    if fallback then arm(self, fallback, port, on_ok, on_fail, arg) end
                    orig(self, addr, port, family, on_ok, on_fail, arg)
                end
                go()
            end
            Dns.resolve(address, function(addrs, err)
                -- 等解析期间请求已取消 / 超时关流（close 只清 socket，不碰 _connecting）或已经失败过：什么都别做。
                if (self.closed and self:closed()) or self._connect_fail_callback ~= fail_callback then return end
                local list = {}
                if type(addrs) == "table" then
                    if addrs.v6 and Patch.hasIPv6() then list[#list + 1] = addrs.v6 end
                    if addrs.v4 then list[#list + 1] = addrs.v4 end
                end
                if #list == 0 then
                    -- 与 turbo 自己解析失败同一条路：立即失败，不让 LuaSocket 再阻塞解析一次。
                    self._handle_connect_fail("DNS resolv error: " .. address .. " (" .. tostring(err) .. ")")
                    return
                end
                dial(list)
            end)
            return 0
        end
    end)

    -- URL 主机是 IPv6 字面量时 Host 要带方括号，否则对端按 RFC 拆不开。
    wrap(HTTPClient, "_prepare_http_request", function(orig)
        return function(self)
            local host = self.hostname
            if type(host) ~= "string" or not host:find(":", 1, true) or host:sub(1, 1) == "[" then
                return orig(self)
            end
            self.hostname = "[" .. host .. "]"
            local req = orig(self)
            self.hostname = host
            return req
        end
    end)

    -- buffer:len() / 已读字节是 FFI int64。stream 的增量路径会 math.min，cdata 直接炸。
    wrap(IOStream, "_read_from_buffer", function(orig)
        return function(self)
            self._read_buffer_size = tonumber(self._read_buffer_size) or 0
            self._read_bytes = tonumber(self._read_bytes)
            return orig(self)
        end
    end)

    -- HTTPParser:get 大小写不敏感分支用的 strncasecmp 靠 io.popen("uname") 选定；
    -- Android 上 popen 拿不到 uname，它是 nil，每个响应头查询都炸（turbo 自己的 HTTPClient 也走这里）。
    local httputil = optional("turbo.httputil")
    wrap(httputil and httputil.HTTPParser, "get", function(orig)
        local ffi = require("ffi")
        return function(self, key, caseinsensitive)
            if caseinsensitive == false then
                return orig(self, key, false)
            end
            local lower, value, count = key:lower(), nil, 0
            for i = 0, (tonumber(self.tpw.hkv_sz) or 0) - 1 do
                local field = self.tpw.hkv[i]
                if ffi.string(field.key, field.key_sz):lower() == lower then
                    local str = ffi.string(field.value, field.value_sz)
                    count = count + 1
                    if value == nil then
                        value = str
                    elseif type(value) == "string" then
                        value = { value, str }
                    else
                        value[#value + 1] = str
                    end
                end
            end
            return value, count
        end
    end)

    -- request_timeout 在 turbo 里是连上后的整包硬超时，大回包 / 大下载慢点就被砍。
    -- 改成空闲超时：每次从 socket 读到数据就把定时器重排，持续有数据不会超时。
    wrap(HTTPClient, "_handle_connect", function(orig)
        return function(self)
            self.iostream._book_client = self
            return orig(self)
        end
    end)
    wrap(IOStream, "_read_to_buffer", function(orig)
        return function(self)
            local sz = orig(self)
            local client = self._book_client
            if sz and sz > 0 and client and client.request_timeout_ref then
                client.io_loop:remove_timeout(client.request_timeout_ref)
                client.request_timeout_ref = client.io_loop:add_timeout(
                    client.kwargs.request_timeout * 1000 + require("turbo.util").gettimemonotonic(),
                    client._handle_request_timeout, client)
            end
            return sz
        end
    end)

    -- 所有连接失败最终都汇到这里：丢弃该主机的 DNS 缓存，坏 IP 不会卡满 TTL。
    -- LuaSocket 异步失败回调是 (client, -1, err)，官方只取第二参，提示成「Could not connect: -1」。
    wrap(HTTPClient, "_handle_connect_fail", function(orig)
        return function(self, rc, err)
            Dns.drop(self.hostname)
            if rc == -1 and err ~= nil then
                rc = err
            end
            return orig(self, rc)
        end
    end)
end

return Patch
