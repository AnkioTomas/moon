--[[--
HTTP 代理：只改单个 HTTPClient 实例，turbo 类不动，KOReader / 其它插件的 turbo 请求照旧直连。

KOReader「HTTP 代理」（socket.http.PROXY）只支持明文 http:// 代理：http 目标发绝对 URI，
https 目标先 CONNECT 建隧道再握手（TLS 仍端到端到目标站）。

@module koplugin.book.http.proxy
--]]

local Patch = require("http.turbo.patch")
local logger = require("utils.log")
local Text = require("utils.text")
local _ = require("gettext")

---@class BookHttpProxy
---@field url string 规范化地址 http://[user:pass@]host:port
---@field host string
---@field port integer
---@field auth string|nil Proxy-Authorization 值

local Proxy = {}

--- 校验并规范化明文 HTTP 代理地址。
--- 与 LuaSocket 同语义：缺省 http://、缺省端口 80，user 与 password 都有才发 Basic 认证，不做 URL 解码。
---@param raw string|nil
---@return BookHttpProxy|nil
---@return string|nil err
function Proxy.parse(raw)
    raw = Text.trim(raw or "")
    if raw == "" then
        return nil, _("代理地址为空")
    end
    local scheme, rest = raw:match("^(%a[%w+.-]*)://(.*)$")
    if scheme and scheme:lower() ~= "http" then
        return nil, _("只支持 http:// 代理")
    end
    rest = rest or raw
    local userinfo, hostport = rest:match("^([^@/]*)@([^/]*)")
    hostport = hostport or rest:match("^[^/]*")
    local host, port = hostport:match("^(.-):(%d+)$")
    host = host or hostport
    port = tonumber(port) or 80
    if host == "" or host:find("[%s:]") or port < 1 or port > 65535 then
        return nil, _("代理地址格式不正确")
    end
    local user, password = (userinfo or ""):match("^([^:]+):(.+)$")
    return {
        url = "http://" .. ((userinfo or "") ~= "" and userinfo .. "@" or "") .. host .. ":" .. port,
        host = host,
        port = port,
        auth = user and ("Basic " .. Text.base64Encode(user .. ":" .. password)) or nil,
    }
end

local warned

--- 读 KOReader 的代理设置（NetworkMgr:setHTTPProxy 写 socket.http.PROXY，关掉时置 nil）。
--- 设过代理 socket.http 必已加载，所以只看 package.loaded，不为读一个字段去加载它。
--- 地址不合法（如 https://）时直连，同一地址只警告一次。
---@return BookHttpProxy|nil
local function current()
    local http = package.loaded["socket.http"]
    local raw = http and http.PROXY
    if not raw or raw == "" then
        return nil
    end
    local proxy, err = Proxy.parse(raw)
    if not proxy and warned ~= raw then
        warned = raw
        logger.warn("book.http proxy unsupported, direct connect", err)
    end
    return proxy
end

--- CONNECT 应答：2xx 恢复 TLS 状态开始握手；否则按连接失败上报（HTTPClient 收到 Could not connect）。
---@param stream table SSLIOStream
---@param data string|nil 应答头
local function onTunnelReply(stream, data)
    local code = tonumber(data and data:match("^HTTP/%d%.%d (%d%d%d)"))
    if code and code >= 200 and code < 300 then
        stream._ssl_accepting = true
        stream:_do_ssl_handshake()
        return
    end
    local errhandler, arg = stream._ssl_connect_errhandler, stream._ssl_connect_callback_arg
    stream._ssl_connect_errhandler, stream._ssl_connect_callback, stream._ssl_connect_callback_arg = nil, nil, nil
    stream:close()
    if errhandler then
        errhandler(arg, -1, "proxy CONNECT " .. tostring(code or "bad response"))
    end
end

--- TCP 连上代理之后、TLS 握手之前插一次 CONNECT：拦截这条流的第一次握手。
--- 交换期间放开 _ssl_accepting，读写走明文 socket；握手的 SNI 用目标主机而不是代理。
---@param stream table SSLIOStream（LuaSocket 版）
---@param host string 目标主机
---@param port integer 目标端口
---@param auth string|nil Proxy-Authorization
local function tunnel(stream, host, port, auth)
    local handshake = stream._do_ssl_handshake
    local target = host .. ":" .. port
    local req = "CONNECT " .. target .. " HTTP/1.1\r\nHost: " .. target .. "\r\n"
        .. (auth and ("Proxy-Authorization: " .. auth .. "\r\n") or "") .. "\r\n"
    stream._ssl_hostname = host
    stream._do_ssl_handshake = function(self)
        -- 连接未建立就来读事件（如被拒）：交回原握手，它会关流。
        if self._connecting then
            return handshake(self)
        end
        self._do_ssl_handshake = nil
        self._ssl_accepting = false
        self:write(req, function()
            self:read_until_pattern("\r?\n\r?\n", onTunnelReply, self)
        end)
    end
end

--- 客户端改走代理：连接先连代理；http 目标请求行换绝对 URI 并带认证头；https 目标建隧道。
---@param client table HTTPClient
---@param proxy BookHttpProxy
local function useProxy(client, proxy)
    local connect, prepare, fail = client._connect, client._prepare_http_request, client._handle_connect_fail
    client._connect = function(self)
        local host, port = self.hostname, self.port
        self.hostname, self.port = proxy.host, proxy.port
        local rc = connect(self)
        self.hostname, self.port = host, port
        if rc == 0 and self.schema == "https" then
            tunnel(self.iostream, host, port, proxy.auth)
        end
        return rc
    end
    client._prepare_http_request = function(self)
        if self.schema ~= "http" then
            return prepare(self)
        end
        local path, on_headers = self.path, self.kwargs.on_headers
        self.path = ("http://%s:%d%s"):format(self.hostname, self.port, path or "/")
        if proxy.auth then
            self.kwargs.on_headers = function(headers)
                if on_headers then on_headers(headers) end
                headers:add("Proxy-Authorization", proxy.auth)
            end
        end
        local req = prepare(self)
        self.path, self.kwargs.on_headers = path, on_headers
        return req
    end
    -- 连不上代理时丢它的 DNS 缓存（类补丁只丢目标主机的）。
    client._handle_connect_fail = function(self, ...)
        Patch.forget(proxy.host)
        return fail(self, ...)
    end
end

--- 让客户端按 KOReader 设置走代理；给了 proxy_url 则只认它（设置页实测未保存的地址），非法即直连。
---@param client table HTTPClient
---@param proxy_url string|nil
function Proxy.apply(client, proxy_url)
    local proxy
    if proxy_url then
        proxy = Proxy.parse(proxy_url)
    else
        proxy = current()
    end
    if proxy then
        useProxy(client, proxy)
    end
end

return Proxy
