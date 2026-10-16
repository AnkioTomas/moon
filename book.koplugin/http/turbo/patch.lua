--[[--
turbo 类补丁 + 主机名 DNS 缓存（会话内只打一次，由 http.turbo 建 loop 时调用）。

补丁：SNI、CA、connect_fail、int64，以及 HTTPParser.get 的 strncasecmp 回退
（turbo 靠 io.popen("uname") 选平台绑定，Android 上 popen 失败留 nil，一读响应头就崩）。

@module koplugin.book.http.turbo.patch
--]]

local Patch = {}

local patched = false

-- LuaSocket connect 按主机名在 UI 线程同步 getaddrinfo，SSL 握手前还会再 connect 一次。
-- 设备上没有系统 DNS 缓存，10 路封面下载就是 20 次阻塞解析；这里按主机名缓存结果。
local DNS_TTL = 10 * 60
local dns = {}
-- 解析失败也记 10 秒：Wi-Fi 连着但上不了网时每次 getaddrinfo 都要阻塞到超时，一屏封面就是十几次。
-- 只挡同一批请求，不能长：刚联网的重试不该吃到联网前的失败。
-- 单独一张表：连接失败会清 dns[host]，不能顺手把失败记录也清了。
local DNS_FAIL_TTL = 10
local dns_fail = {}

--- 主机名换成缓存地址；IP 字面量原样返回，解析失败（含 10 秒内失败过）返回 nil。
---@param host string
---@return string|nil
local function resolve(host)
    if host:match("^[%d%.]+$") or host:find(":", 1, true) then
        return host
    end
    local now = os.time()
    local hit = dns[host]
    if hit and hit.expires > now then
        return hit.addr
    end
    if (dns_fail[host] or 0) > now then
        return nil
    end
    local list = require("socket").dns.getaddrinfo(host)
    local addr = list and list[1] and list[1].addr
    if not addr then
        dns_fail[host] = now + DNS_FAIL_TTL
        return nil
    end
    dns_fail[host] = nil
    dns[host] = { addr = addr, expires = now + DNS_TTL }
    return addr
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

    -- `self._handle_connect_fail(err)` 点号调用会把 self 变成错误字符串；主机名解析收口到 resolve。
    wrap(IOStream, "connect", function(orig)
        local orig_fail = IOStream._handle_connect_fail
        return function(self, address, port, family, callback, fail_callback, arg)
            self._handle_connect_fail = function(first, second)
                if type(first) ~= "table" then
                    return orig_fail(self, first)
                end
                return orig_fail(first, second)
            end
            local addr = resolve(address)
            if not addr then
                -- 与 turbo 自己解析失败同一条路：登记失败回调后立即失败，不让 LuaSocket 再阻塞解析一次。
                self._connect_fail_callback, self._connect_callback_arg = fail_callback, arg
                return self._handle_connect_fail("DNS resolv error: " .. address)
            end
            return orig(self, addr, port, family, callback, fail_callback, arg)
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

    -- 所有连接失败最终都汇到这里：丢弃该主机的 DNS 缓存，坏 IP 不会卡满 TTL。
    -- LuaSocket 异步失败回调是 (client, -1, err)，官方只取第二参，提示成「Could not connect: -1」。
    wrap(HTTPClient, "_handle_connect_fail", function(orig)
        return function(self, rc, err)
            dns[self.hostname] = nil
            if rc == -1 and err ~= nil then
                rc = err
            end
            return orig(self, rc)
        end
    end)
end

--- 丢弃主机的 DNS 缓存，下次连接重新解析。
---@param host string
function Patch.forget(host)
    dns[host] = nil
    dns_fail[host] = nil
end

return Patch
