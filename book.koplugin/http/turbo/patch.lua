--[[--
turbo 类补丁（会话内只打一次，由 http.turbo 建 loop 时调用）。主机名解析交给 http.dns（非阻塞 UDP）。

补丁：SNI、CA、connect_fail、int64，以及 HTTPParser.get 的 strncasecmp 回退
（turbo 靠 io.popen("uname") 选平台绑定，Android 上 popen 失败留 nil，一读响应头就崩）。

@module koplugin.book.http.turbo.patch
--]]

local Patch = {}

local patched = false

local Dns = require("http.dns")

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

    -- `self._handle_connect_fail(err)` 点号调用会把 self 变成错误字符串；主机名解析收口到 Dns.resolve（不阻塞）。
    -- HTTPClient 不看 connect 的返回值，只等 _handle_connect / _handle_connect_fail（外加自己的 connect 超时），
    -- 所以解析可以异步：先登记失败回调，地址到了再真正 connect。
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
            Dns.resolve(address, function(addr, err)
                -- 等解析期间请求已取消 / 超时关流（close 只清 socket，不碰 _connecting）或已经失败过：什么都别做。
                if (self.closed and self:closed()) or self._connect_fail_callback ~= fail_callback then return end
                if not addr then
                    -- 与 turbo 自己解析失败同一条路：立即失败，不让 LuaSocket 再阻塞解析一次。
                    self._handle_connect_fail("DNS resolv error: " .. address .. " (" .. tostring(err) .. ")")
                    return
                end
                orig(self, addr, port, family, callback, fail_callback, arg)
            end)
            return 0
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
            Dns.drop(self.hostname)
            if rc == -1 and err ~= nil then
                rc = err
            end
            return orig(self, rc)
        end
    end)
end

return Patch
