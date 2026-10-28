--[[--
非阻塞 DNS：自己发 UDP 查询（A 记录），不碰 getaddrinfo。

LuaSocket 按主机名 connect 会在 UI 线程同步 getaddrinfo；设备上没有系统 DNS 缓存，Wi-Fi 连着但 DNS 不通时
一次就阻塞到 resolver 超时（A + AAAA、两个 nameserver 下 20～40 秒），翻页、顶栏全点不动。
这里用 ``socket.udp`` 零超时收发，经 UIManager 轮询等应答，主进程不等任何 IO。

每次查询把同一个包同时发给系统 DNS 和设置 ``http.dns`` 选的备选 DNS（阿里 / 腾讯，各两台），
谁先应答用谁：路由器 DNS 挂了不用等它超时，备选被墙了系统的还在。
系统 DNS 问 libc 自己的 resolver 状态（和 getaddrinfo 用的同一份，见 ``Dns.libcServers``），
Android 经 JNI 问 ConnectivityManager，都拿不到才读 /etc/resolv.conf。解析结果缓存 10 分钟；
查无此域名 / 没应答只记这一个主机 10 秒。一个包都发不出去（没网 "Network is unreachable"）当场失败，不记、不等。

@module koplugin.book.http.dns
--]]

local Dns = {}

---@class DnsProvider 备选 DNS
---@field id string 设置值
---@field name string 显示名
---@field servers string[]

---@type DnsProvider[]
Dns.PROVIDERS = {
    { id = "ali", name = "阿里 DNS", servers = { "223.5.5.5", "223.6.6.6" } },
    { id = "tencent", name = "腾讯 DNS", servers = { "119.29.29.29", "182.254.116.116" } },
}
Dns.DEFAULT = "ali"
Dns.PORT = 53
Dns.TTL = 10 * 60
Dns.FAIL_TTL = 10
--- 等任一服务器应答的秒数；全部都没应答才算 DNS 不通。
Dns.QUERY_TIMEOUT = 3
Dns.POLL = 0.05
--- libc 拿不到 nameserver 时的兜底（musl 的 res_init 是空操作）。
Dns.RESOLV_CONF = "/etc/resolv.conf"

---@type table<string, { addr: string, expires: integer }>
local cache = {}
---@type table<string, integer> 主机 → 失败记录过期时刻
local fail = {}
---@type table<string, fun(addr: string|nil, err: string|nil)[]> 在飞查询的等待者
local pending = {}

---@param id string|nil
---@return DnsProvider
function Dns.provider(id)
    for _idx, p in ipairs(Dns.PROVIDERS) do
        if p.id == id then return p end
    end
    return Dns.provider(Dns.DEFAULT)
end

--- 当前设置选中的备选 DNS。设置模块拿不到（精简测试桩）按缺省。
---@return DnsProvider
function Dns.current()
    local ok, cfg = pcall(function() return require("utils.settings").get("http") end)
    return Dns.provider(ok and type(cfg) == "table" and cfg.dns or nil)
end

---@type table|false|nil ffi 模块；false = 不可用
local ffi_mod

--- 声明只做一次；同名原型 KOReader 别处可能已声明，重复声明会报错，逐条 pcall。
---@return table|false
local function ffiModule()
    if ffi_mod ~= nil then return ffi_mod end
    local ok, ffi = pcall(require, "ffi")
    ffi_mod = ok and ffi or false
    if not ffi_mod then return false end
    for _idx, decl in ipairs({
        "typedef struct { uint16_t family; uint16_t port; uint8_t addr[4]; uint8_t zero[8]; } book_dns_sockaddr_in;",
        "typedef struct { int retrans; int retry; unsigned long options; int nscount; book_dns_sockaddr_in ns[3]; } book_dns_res_prefix;",
        "int __res_init(void);",
        "void *__res_state(void);",
        "int res_9_ninit(void *statp);",
        "int res_9_getservers(void *statp, void *set, int cnt);",
        "void res_9_ndestroy(void *statp);",
        "int __system_property_get(const char *name, char *value);",
    }) do
        pcall(ffi.cdef, decl)
    end
    return ffi_mod
end

---@param b table|ffi.cdata* 4 字节，网络序
---@return string
local function ip4(b)
    return string.format("%d.%d.%d.%d", b[0], b[1], b[2], b[3])
end

--- 系统 resolver 自己配置的 IPv4 nameserver（getaddrinfo 用的同一份）；拿不到为空表。
---   - glibc（Kindle / Kobo / PocketBook）：__res_init + __res_state，前缀布局自 BIND 4 起未变，armv7 / arm64 实测；
---   - macOS（模拟器）：libSystem 的 res_init 是空壳，走 libresolv 的 res_9_ninit + res_9_getservers；
---   - Android（bionic 独有 __system_property_get 作为识别）：经 JNI 问 ConnectivityManager，见 Dns.androidServers；
---   - musl：res_init 是空操作，没有 __res_init，返回空表 → 调用方读 resolv.conf。
---@return string[]
function Dns.libcServers()
    local ffi = ffiModule()
    if not ffi then return {} end
    local out = {}
    if ffi.os == "OSX" then
        pcall(function()
            local resolv = ffi.load("resolv")
            local statp = ffi.new("uint8_t[?]", 8192)
            if resolv.res_9_ninit(statp) ~= 0 then return end
            -- union res_sockaddr_union 每项 128 字节：[1] 族，[2..3] 端口，[4..7] IPv4
            local set = ffi.new("uint8_t[?]", 128 * 8)
            for i = 0, resolv.res_9_getservers(statp, set, 8) - 1 do
                local p = set + 128 * i
                if p[1] == 2 then out[#out + 1] = ip4(p + 4) end
            end
            resolv.res_9_ndestroy(statp)
        end)
        return out
    end
    if pcall(function() return ffi.C.__system_property_get end) then
        return Dns.androidServers(ffi)
    end
    pcall(function()
        if ffi.C.__res_init() ~= 0 then return end
        local st = ffi.cast("book_dns_res_prefix*", ffi.C.__res_state())
        for i = 0, math.min(tonumber(st.nscount) or 0, 3) - 1 do
            if st.ns[i].family == 2 then out[#out + 1] = ip4(st.ns[i].addr) end
        end
    end)
    return out
end

--- Android：DNS 在 ConnectivityService 的 LinkProperties 里，原生层没有（8.0 起 net.dns* 属性为空、也没有 resolv.conf），
--- 经 KOReader 启动器的 JNI 桥调 ConnectivityManager.getLinkProperties(getActiveNetwork()).getDnsServers()。
--- 任一步 Java 抛异常就清掉返回已拿到的部分（不清下一次 JNI 调用会崩进程）。
---@param ffi table
---@return string[]
function Dns.androidServers(ffi)
    local out = {}
    local ok, android = pcall(require, "android")
    if not ok or type(android) ~= "table" or not android.jni or not android.app then return out end
    pcall(android.jni.context, android.jni, android.app.activity.vm, function(jni)
        local env = jni.env
        local function failed()
            if env[0].ExceptionCheck(env) == 0 then return false end
            env[0].ExceptionClear(env)
            return true
        end
        local name = env[0].NewStringUTF(env, "connectivity")
        local cm = jni:callObjectMethod(android.app.activity.clazz, "getSystemService",
            "(Ljava/lang/String;)Ljava/lang/Object;", name)
        env[0].DeleteLocalRef(env, name)
        if failed() or cm == nil then return end
        local network = jni:callObjectMethod(cm, "getActiveNetwork", "()Landroid/net/Network;")
        if failed() or network == nil then return end
        local lp = jni:callObjectMethod(cm, "getLinkProperties",
            "(Landroid/net/Network;)Landroid/net/LinkProperties;", network)
        if failed() or lp == nil then return end
        local list = jni:callObjectMethod(lp, "getDnsServers", "()Ljava/util/List;")
        if failed() or list == nil then return end
        local count = jni:callIntMethod(list, "size", "()I")
        if failed() then return end
        for i = 0, count - 1 do
            -- 可变参数里的 Lua number 会按 double 传，jint 必须显式 cast
            local addr = jni:callObjectMethod(list, "get", "(I)Ljava/lang/Object;", ffi.cast("int32_t", i))
            if failed() or addr == nil then return end
            local jstr = jni:callObjectMethod(addr, "getHostAddress", "()Ljava/lang/String;")
            if failed() or jstr == nil then return end
            local ip = jni:to_string(jstr)
            env[0].DeleteLocalRef(env, jstr)
            env[0].DeleteLocalRef(env, addr)
            if ip:match("^%d+%.%d+%.%d+%.%d+$") then out[#out + 1] = ip end
        end
    end)
    return out
end

--- 兜底：/etc/resolv.conf 里的 IPv4 nameserver；读不到为空表。
---@return string[]
local function resolvConfServers()
    local out = {}
    local f = io.open(Dns.RESOLV_CONF, "r")
    if not f then return out end
    for line in f:lines() do
        local ip = line:match("^%s*nameserver%s+([%d%.]+)")
        if ip then out[#out + 1] = ip end
    end
    f:close()
    return out
end

--- 系统 DNS：先问 libc，拿不到再读 resolv.conf。
---@return string[]
function Dns.systemServers()
    local list = Dns.libcServers()
    if #list > 0 then return list end
    return resolvConfServers()
end

--- 本次查询同时问的服务器：系统 DNS 在前、备选在后，去重；备选保证非空。
---@return string[]
function Dns.servers()
    local out, seen = {}, {}
    local function add(ip)
        if not seen[ip] then
            seen[ip] = true
            out[#out + 1] = ip
        end
    end
    for _idx, ip in ipairs(Dns.systemServers()) do add(ip) end
    for _idx, ip in ipairs(Dns.current().servers) do add(ip) end
    return out
end

---@param n integer
---@return string
local function u16(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

---@param s string
---@param pos integer
---@return integer
local function rd16(s, pos)
    local a, b = s:byte(pos, pos + 1)
    return a * 256 + b
end

--- 一条 A 查询报文（递归期望）。
---@param host string
---@param id integer 1～65535
---@return string
function Dns.encode(host, id)
    local parts = { u16(id), "\1\0", u16(1), u16(0), u16(0), u16(0) }
    for label in host:gmatch("[^%.]+") do
        parts[#parts + 1] = string.char(#label) .. label
    end
    parts[#parts + 1] = "\0" .. u16(1) .. u16(1)
    return table.concat(parts)
end

--- 跳过一个域名（含压缩指针），返回其后位置；报文截断返回 nil。
---@param s string
---@param pos integer
---@return integer|nil
local function skipName(s, pos)
    while true do
        local len = s:byte(pos)
        if not len then return nil end
        if len >= 0xC0 then return pos + 2 end
        if len == 0 then return pos + 1 end
        pos = pos + 1 + len
    end
end

--- 解出应答里的第一个 A 记录。
---@param s string 报文
---@param id integer 期望的查询 ID
---@return string|nil addr
---@return string|nil err "mismatch"（不是我的应答，继续等）/ "nxdomain"（无此域名）/ "noanswer"（有应答但没有 A）/ "rcode N"
function Dns.decode(s, id)
    if #s < 12 or rd16(s, 1) ~= id then return nil, "mismatch" end
    local flags_hi, flags_lo = s:byte(3, 4)
    if flags_hi < 0x80 then return nil, "mismatch" end
    local rcode = flags_lo % 16
    if rcode == 3 then return nil, "nxdomain" end
    if rcode ~= 0 then return nil, "rcode " .. rcode end
    local qd, an = rd16(s, 5), rd16(s, 7)
    local pos = 13
    for _q = 1, qd do
        pos = skipName(s, pos)
        if not pos then return nil, "noanswer" end
        pos = pos + 4
    end
    for _a = 1, an do
        pos = skipName(s, pos)
        if not pos or #s < pos + 9 then return nil, "noanswer" end
        local rtype, rdlen = rd16(s, pos), rd16(s, pos + 8)
        pos = pos + 10
        if rtype == 1 and rdlen == 4 then
            local a, b, c, d = s:byte(pos, pos + 3)
            return string.format("%d.%d.%d.%d", a, b, c, d)
        end
        pos = pos + rdlen
    end
    return nil, "noanswer"
end

--- 同一个查询同时发给所有 servers，谁先应答用谁；异步回 cb(addr) 或 cb(nil, err)，
--- err 为 "nxdomain" / "noanswer" / "rcode N"（有服务器答了）或 "timeout"（QUERY_TIMEOUT 内全没应答）。
--- 本机就发不出去（建不出 socket、没网 "Network is unreachable"）同步返回 nil, err，不回调。
---@param host string
---@param servers string[]
---@param cb fun(addr: string|nil, err: string|nil)
---@return true|nil
---@return string|nil err
local function query(host, servers, cb)
    local socket = require("socket")
    local UIManager = require("ui/uimanager")
    local udp, udp_err = socket.udp()
    if not udp then return nil, "socket " .. tostring(udp_err) end
    udp:settimeout(0)
    local id = math.random(1, 65535)
    local packet = Dns.encode(host, id)
    local sent, send_err = 0, nil
    for _idx, server in ipairs(servers) do
        local ok, err = udp:sendto(packet, server, Dns.PORT)
        if ok then sent = sent + 1 else send_err = err end
    end
    if sent == 0 then
        udp:close()
        return nil, "sendto " .. tostring(send_err)
    end
    local deadline = socket.gettime() + Dns.QUERY_TIMEOUT
    local function poll()
        local data = udp:receivefrom()
        while data do
            local addr, err = Dns.decode(data, id)
            if err ~= "mismatch" then
                -- 第一个有效应答定结果（含 NXDOMAIN），其余的随 socket 关闭丢掉
                udp:close()
                cb(addr, err)
                return
            end
            data = udp:receivefrom()
        end
        if socket.gettime() >= deadline then
            udp:close()
            cb(nil, "timeout")
            return
        end
        UIManager:scheduleIn(Dns.POLL, poll)
    end
    UIManager:scheduleIn(Dns.POLL, poll)
    return true
end

--- 主机名换地址，回调 cb(addr) 或 cb(nil, err)：IP 字面量 / 缓存命中 / 发不出去同步回调；
--- 10 秒内失败过的直接回 nil；否则发查询，同主机并发只查一次、一起回。
---@param host string
---@param cb fun(addr: string|nil, err: string|nil)
function Dns.resolve(host, cb)
    if host:match("^[%d%.]+$") or host:find(":", 1, true) then
        cb(host)
        return
    end
    local now = os.time()
    local hit = cache[host]
    if hit and hit.expires > now then
        cb(hit.addr)
        return
    end
    if (fail[host] or 0) > now then
        cb(nil, "failed recently")
        return
    end
    local waiters = pending[host]
    if waiters then
        waiters[#waiters + 1] = cb
        return
    end
    waiters = { cb }
    pending[host] = waiters
    local function settle(addr, err)
        pending[host] = nil
        if addr then
            fail[host] = nil
            cache[host] = { addr = addr, expires = os.time() + Dns.TTL }
        else
            fail[host] = os.time() + Dns.FAIL_TTL
            if err == "timeout" then
                require("utils.log").warn("book.dns no response", host, table.concat(Dns.servers(), ","))
            end
        end
        for _idx, waiter in ipairs(waiters) do waiter(addr, err) end
    end
    local ok, err = query(host, Dns.servers(), settle)
    if not ok then
        -- 本机问题，不是这个主机的问题：不记失败，网一回来下次就能查
        pending[host] = nil
        cb(nil, err)
    end
end

--- 丢掉主机的地址缓存（连接失败：坏 IP 不能卡满 TTL）；失败记录保留，仍挡住同一批请求。
---@param host string
function Dns.drop(host)
    cache[host] = nil
end

--- 地址缓存与失败记录一起清，下次连接重新解析。
---@param host string
function Dns.forget(host)
    cache[host] = nil
    fail[host] = nil
end

--- 换备选 DNS：全部重解析，失败记录也作废。
function Dns.clear()
    cache, fail, pending = {}, {}, {}
end

return Dns
