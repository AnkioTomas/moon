--[[--
非阻塞 DNS：自己发 UDP 查询（A 与 AAAA），不碰 getaddrinfo。

LuaSocket 按主机名 connect 会在 UI 线程同步 getaddrinfo；设备上没有系统 DNS 缓存，Wi-Fi 连着但 DNS 不通时
一次就阻塞到 resolver 超时（A + AAAA、两个 nameserver 下 20～40 秒），翻页、顶栏全点不动。
这里用 ``socket.udp`` / ``socket.udp6`` 零超时收发，经 UIManager 轮询等应答，主进程不等任何 IO。

每次查询把 A 和 AAAA 两个包同时发给系统 DNS 和设置 ``http.dns`` 选的备选 DNS（阿里 / 腾讯，IPv4 / IPv6 各两台）。
地址到了就用，另一族再等一轮轮询；A 查询的 NXDOMAIN 表示名字不存在，当场定局。
SERVFAIL / REFUSED / 没有该类型记录继续等别的服务器。查询前先看用户绑定（设置 ``http.dns_bind``，
内网主机直接给地址，公网 DNS 对这种名字会秒回 NXDOMAIN 并抢先定局）和 /etc/hosts。
系统 DNS 问 libc 自己的 resolver 状态（和 getaddrinfo 用的同一份，见 ``Dns.libcServers``），
Android 经 JNI 问 ConnectivityManager，再并上 /etc/resolv.conf 里 libc 结构体装不下的 IPv6。
解析结果缓存 10 分钟（两族一起）；两族都没有只记这一个主机 10 秒。
一个包都发不出去（没网 "Network is unreachable"）当场失败，不记、不等。

连接侧拿 ``{ v4, v6 }`` 自己选地址族，见 ``http.turbo.patch``。

@module koplugin.book.http.dns
--]]

local Dns = {}

---@class DnsProvider 备选 DNS
---@field id string 设置值
---@field name string 显示名
---@field servers string[]

---@type DnsProvider[]
Dns.PROVIDERS = {
    { id = "ali", name = "阿里 DNS", servers = { "223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1" } },
    { id = "tencent", name = "腾讯 DNS", servers = { "119.29.29.29", "182.254.116.116", "2402:4e00::", "2402:4e00:1::" } },
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
Dns.HOSTS = "/etc/hosts"

--- 一次解析的两族地址。至少有一族才算成功。
---@class DnsAddrs
---@field v4 string|nil
---@field v6 string|nil

---@type table<string, { v4: string|nil, v6: string|nil, expires: integer }>
local cache = {}
---@type table<string, integer> 主机 → 失败记录过期时刻
local fail = {}
---@type table<string, fun(addrs: DnsAddrs|nil, err: string|nil)[]> 在飞查询的等待者
local pending = {}

---@param id string|nil
---@return DnsProvider
function Dns.provider(id)
    for _idx, p in ipairs(Dns.PROVIDERS) do
        if p.id == id then return p end
    end
    return Dns.provider(Dns.DEFAULT)
end

--- 当前设置选中的备选 DNS。
---@return DnsProvider
function Dns.current()
    return Dns.provider(require("utils.settings").get("http").dns)
end

---@type table|nil 声明过原型的 ffi 模块
local ffi_mod

--- 声明只做一次；同名原型 KOReader 别处可能已声明，重复声明会报错，逐条 pcall。
---@return table
local function ffiModule()
    if ffi_mod then return ffi_mod end
    local ffi = require("ffi")
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
    ffi_mod = ffi
    return ffi
end

---@param b table|ffi.cdata* 4 字节，网络序
---@return string
local function ip4(b)
    return string.format("%d.%d.%d.%d", b[0], b[1], b[2], b[3])
end

--- 8 个 16 位组压成文本。最长的一段连续 0（至少两组）收成 ``::``。
---@param words integer[]
---@return string
local function compressIp6(words)
    local best_at, best_len, run_at = 0, 0, nil
    for i = 1, 9 do
        if i <= 8 and words[i] == 0 then
            run_at = run_at or i
        else
            if run_at and i - run_at > best_len then
                best_at, best_len = run_at, i - run_at
            end
            run_at = nil
        end
    end
    if best_len < 2 then best_at = 0 end
    local parts, i = {}, 1
    while i <= 8 do
        if i == best_at then
            parts[#parts + 1] = "::"
            i = i + best_len
        else
            parts[#parts + 1] = string.format("%x", words[i])
            i = i + 1
            if i <= 8 and i ~= best_at then parts[#parts + 1] = ":" end
        end
    end
    return table.concat(parts)
end

---@param s string
---@param pos integer 1-based
---@return string
local function ip6at(s, pos)
    local words = {}
    for i = 0, 7 do
        local hi, lo = s:byte(pos + i * 2, pos + i * 2 + 1)
        words[i + 1] = hi * 256 + lo
    end
    return compressIp6(words)
end

---@param b ffi.cdata* 16 字节，网络序
---@return string
local function ip6ffi(b)
    local words = {}
    for i = 0, 7 do
        words[i + 1] = b[i * 2] * 256 + b[i * 2 + 1]
    end
    return compressIp6(words)
end

--- 系统 resolver 自己配置的 IPv4 nameserver（getaddrinfo 用的同一份）；拿不到为空表。
---   - glibc（Kindle / Kobo / PocketBook）：__res_init + __res_state，前缀布局自 BIND 4 起未变，armv7 / arm64 实测；
---   - macOS（模拟器）：libSystem 的 res_init 是空壳，走 libresolv 的 res_9_ninit + res_9_getservers；
---   - Android（bionic 独有 __system_property_get 作为识别）：经 JNI 问 ConnectivityManager，见 Dns.androidServers；
---   - musl：res_init 是空操作，没有 __res_init，返回空表 → 调用方读 resolv.conf。
---@return string[]
function Dns.libcServers()
    local ffi = ffiModule()
    local out = {}
    if ffi.os == "OSX" then
        pcall(function()
            local resolv = ffi.load("resolv")
            local statp = ffi.new("uint8_t[?]", 8192)
            if resolv.res_9_ninit(statp) ~= 0 then return end
            -- union res_sockaddr_union 每项 128 字节。BSD sockaddr： [0] 长度、[1] 族。
            -- AF_INET=2，地址在 +4；AF_INET6=30，地址在 +8（端口 2、flowinfo 4 之后）。
            local set = ffi.new("uint8_t[?]", 128 * 8)
            for i = 0, resolv.res_9_getservers(statp, set, 8) - 1 do
                local p = set + 128 * i
                if p[1] == 2 then
                    out[#out + 1] = ip4(p + 4)
                elseif p[1] == 30 then
                    out[#out + 1] = ip6ffi(p + 8)
                end
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

--- Android 6.0 起经 JNI 取 LinkProperties 的 DNS；旧版读 net.dns*（8.0 起这些属性为空）。
--- getActiveNetwork 是 API 23，旧版 JNI 包装会拿空 methodID 调用，ExceptionCheck 来不及保护。
--- 任一步 Java 抛异常就清掉返回已拿到的部分（不清下一次 JNI 调用会崩进程）。
---@param ffi table
---@return string[]
function Dns.androidServers(ffi)
    local out = {}
    local ok, android = pcall(require, "android")
    if not ok or type(android) ~= "table" or not android.jni or not android.app then return out end
    if android.app.activity.sdkVersion < 23 then
        local value = ffi.new("char[92]") -- Android PROP_VALUE_MAX
        for i = 1, 4 do
            local size = ffi.C.__system_property_get("net.dns" .. i, value)
            if size > 0 then
                local ip = ffi.string(value, size)
                if ip:match("^%d+%.%d+%.%d+%.%d+$") or ip:find(":", 1, true) then
                    out[#out + 1] = ip
                end
            end
        end
        return out
    end
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
            if ip:match("^%d+%.%d+%.%d+%.%d+$") or ip:find(":", 1, true) then
                out[#out + 1] = ip
            end
        end
    end)
    return out
end

--- /etc/resolv.conf 里的 nameserver（IPv4 或 IPv6，链路本地可带 %zone）；读不到为空表。
---@return string[]
local function resolvConfServers()
    local out = {}
    local f = io.open(Dns.RESOLV_CONF, "r")
    if not f then return out end
    for line in f:lines() do
        local ip = line:match("^%s*nameserver%s+(%S+)")
        if ip and (ip:match("^%d+%.%d+%.%d+%.%d+$") or ip:find(":", 1, true)) then
            out[#out + 1] = ip
        end
    end
    f:close()
    return out
end

--- 系统 DNS：libc 能读到的（glibc 前缀只有 IPv4）再并上 resolv.conf，去重。
--- glibc 把 IPv6 名字服务器放在不稳定的扩展结构里，不挖它，resolv.conf 就是那份。
---@return string[]
function Dns.systemServers()
    local out, seen = {}, {}
    local function add(ip)
        if not seen[ip] then
            seen[ip] = true
            out[#out + 1] = ip
        end
    end
    for _idx, ip in ipairs(Dns.libcServers()) do add(ip) end
    for _idx, ip in ipairs(resolvConfServers()) do add(ip) end
    return out
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

--- 一条查询报文（递归期望）。qtype 1 = A，28 = AAAA。
---@param host string
---@param id integer 1～65535
---@param qtype integer|nil 缺省 A
---@return string
function Dns.encode(host, id, qtype)
    local parts = { u16(id), "\1\0", u16(1), u16(0), u16(0), u16(0) }
    for label in host:gmatch("[^%.]+") do
        parts[#parts + 1] = string.char(#label) .. label
    end
    parts[#parts + 1] = "\0" .. u16(qtype or 1) .. u16(1)
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

--- 解出应答里第一个指定类型的地址。qtype 缺省 A；AAAA 要 16 字节。
---@param s string 报文
---@param id integer 期望的查询 ID
---@param qtype integer|nil
---@return string|nil addr
---@return string|nil err "mismatch"（不是我的应答，继续等）/ "nxdomain"（无此域名）/ "noanswer"（有应答但没有该类型）/ "rcode N"
function Dns.decode(s, id, qtype)
    qtype = qtype or 1
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
    local width = qtype == 28 and 16 or 4
    for _a = 1, an do
        pos = skipName(s, pos)
        if not pos or #s < pos + 9 then return nil, "noanswer" end
        local rtype, rdlen = rd16(s, pos), rd16(s, pos + 8)
        pos = pos + 10
        if rtype == qtype and rdlen == width and #s >= pos + width - 1 then
            if qtype == 28 then return ip6at(s, pos) end
            local a, b, c, d = s:byte(pos, pos + 3)
            return string.format("%d.%d.%d.%d", a, b, c, d)
        end
        pos = pos + rdlen
    end
    return nil, "noanswer"
end

---@param v6 boolean
---@return table|nil udp
---@return string|nil err
local function openUdp(v6)
    local socket = require("socket")
    local make = v6 and socket.udp6 or socket.udp
    if type(make) ~= "function" then return nil, v6 and "no udp6" or "no udp" end
    local udp, err = make()
    if not udp then return nil, err end
    udp:settimeout(0)
    return udp
end

--- A 与 AAAA 同时发给所有 servers。回 cb(addrs) 或 cb(nil, err)。
--- err 为 "nxdomain"（A 查询认定名字不存在）/ "noanswer" / "rcode N" / "timeout"。
--- 本机一个包都发不出去时同步返回 nil, err，不回调。
---@param host string
---@param servers string[]
---@param cb fun(addrs: DnsAddrs|nil, err: string|nil)
---@return true|nil
---@return string|nil err
local function query(host, servers, cb)
    local socket = require("socket")
    local UIManager = require("ui/uimanager")
    local v4s, v6s = {}, {}
    for _idx, server in ipairs(servers) do
        if server:find(":", 1, true) then v6s[#v6s + 1] = server else v4s[#v4s + 1] = server end
    end
    -- 两个 id 紧挨着，应答按 id 分到 A / AAAA。同一查询的两族 socket 共用这一对。
    local id_a = math.random(1, 65534)
    local packet_a = Dns.encode(host, id_a, 1)
    local packet_aaaa = Dns.encode(host, id_a + 1, 28)
    local socks, open_err = {}, nil
    local function add(v6, list)
        if #list == 0 then return end
        local udp, err = openUdp(v6)
        if not udp then open_err = err; return end
        socks[#socks + 1] = { udp = udp, servers = list }
    end
    add(false, v4s)
    add(true, v6s)
    if #socks == 0 then return nil, "socket " .. tostring(open_err) end
    local sent, send_err = 0, nil
    for _idx, item in ipairs(socks) do
        for _j, server in ipairs(item.servers) do
            for _k, packet in ipairs({ packet_a, packet_aaaa }) do
                local ok, err = item.udp:sendto(packet, server, Dns.PORT)
                if ok then sent = sent + 1 else send_err = err end
            end
        end
    end
    if sent == 0 then
        for _idx, item in ipairs(socks) do item.udp:close() end
        return nil, "sendto " .. tostring(send_err)
    end
    local deadline = socket.gettime() + Dns.QUERY_TIMEOUT
    -- 一族到了再等一轮轮询收另一族（应答经常紧跟着进同一个 socket）。
    -- A 的 NXDOMAIN 按 RFC 是名字不存在，不等 AAAA。SERVFAIL / 没有该类型继续等。
    local got_v4, got_v6, nx_a, answered, last_err, waiting, settled = nil, nil, false, 0, nil, false, false
    local function finish(err)
        if settled then return end
        settled = true
        for _idx, item in ipairs(socks) do item.udp:close() end
        if got_v4 or got_v6 then cb({ v4 = got_v4, v6 = got_v6 }) else cb(nil, err or last_err or "timeout") end
    end
    local function take(data, _item)
        local addr, err = Dns.decode(data, id_a, 1)
        local qtype = 1
        if err == "mismatch" then
            addr, err = Dns.decode(data, id_a + 1, 28)
            qtype = 28
            if err == "mismatch" then return end
        end
        answered = answered + 1
        if addr then
            -- 同类型先到的为准，后面的服务器不能把已经定下的地址盖掉。
            if qtype == 28 then got_v6 = got_v6 or addr else got_v4 = got_v4 or addr end
        elseif err == "nxdomain" then
            if qtype == 1 then nx_a = true end
        else
            last_err = err
        end
    end
    local function poll()
        for _idx, item in ipairs(socks) do
            local data = item.udp:receivefrom()
            while data do
                take(data, item)
                data = item.udp:receivefrom()
            end
        end
        if nx_a and not got_v4 and not got_v6 then return finish("nxdomain") end
        if got_v4 and got_v6 then return finish() end
        if got_v4 or got_v6 then
            if waiting or answered >= sent or socket.gettime() >= deadline then return finish() end
            waiting = true
            UIManager:scheduleIn(Dns.POLL, poll)
            return
        end
        if answered >= sent or socket.gettime() >= deadline then return finish() end
        UIManager:scheduleIn(Dns.POLL, poll)
    end
    UIManager:scheduleIn(Dns.POLL, poll)
    return true
end

--- /etc/hosts 里的静态条目（自建服务常靠它指到内网机器；getaddrinfo 会读，自己发 UDP 就绕开了）。
--- IPv4 与 IPv6 都认；文件不存在 / 没命中回 nil。只在缓存未命中时读一次，不缓存文件内容。
---@param host string
---@return string|nil addr
function Dns.hostsLookup(host)
    local f = io.open(Dns.HOSTS, "r")
    if not f then return nil end
    local want = host:lower()
    for line in f:lines() do
        local fields = line:gsub("#.*$", "")
        local addr, names = fields:match("^%s*(%S+)%s+(.-)%s*$")
        if addr and (addr:match("^%d+%.%d+%.%d+%.%d+$") or addr:find(":", 1, true)) then
            for name in names:gmatch("%S+") do
                if name:lower() == want then
                    f:close()
                    return addr
                end
            end
        end
    end
    f:close()
    return nil
end

--- 用户绑定的地址（设置 http.dns_bind，键是小写主机名，末尾点忽略，值是 IPv4 或 IPv6）。没有返回 nil。
--- 缺这张表、或值不是非空字符串，当成没绑定：坏配置不能让所有请求在解析这步炸掉。
---@param host string
---@return string|nil
function Dns.binding(host)
    local map = require("utils.settings").get("http").dns_bind
    if type(map) ~= "table" then return nil end
    local addr = map[host:lower():gsub("%.$", "")]
    if type(addr) ~= "string" or addr == "" then return nil end
    return addr
end

---@param addr string
---@return DnsAddrs
local function pack(addr)
    if addr:find(":", 1, true) then return { v6 = addr } end
    return { v4 = addr }
end

--- 主机名换地址，回调 cb(addrs) 或 cb(nil, err)：IP 字面量 / 用户绑定 / /etc/hosts / 缓存命中 / 发不出去同步回调。
--- addrs 是 ``{ v4, v6 }``，至少一族。10 秒内失败过的直接回 nil；否则发查询，同主机并发只查一次、一起回。
--- 绑定不进缓存：改完下一次就生效，连接失败也不会退回去再查 DNS。
---@param host string
---@param cb fun(addrs: DnsAddrs|nil, err: string|nil)
function Dns.resolve(host, cb)
    local bare = host:match("^%[(.+)%]$")
    if bare then host = bare end
    if host:match("^[%d%.]+$") or host:find(":", 1, true) then
        cb(pack(host))
        return
    end
    local bound = Dns.binding(host)
    if bound then
        cb(pack(bound))
        return
    end
    local now = os.time()
    local hit = cache[host]
    if hit and hit.expires > now then
        cb({ v4 = hit.v4, v6 = hit.v6 })
        return
    end
    local static = Dns.hostsLookup(host)
    if static then
        local addrs = pack(static)
        cache[host] = { v4 = addrs.v4, v6 = addrs.v6, expires = now + Dns.TTL }
        cb(addrs)
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
    local function settle(addrs, err)
        pending[host] = nil
        if addrs then
            fail[host] = nil
            cache[host] = { v4 = addrs.v4, v6 = addrs.v6, expires = os.time() + Dns.TTL }
        else
            fail[host] = os.time() + Dns.FAIL_TTL
            if err == "timeout" then
                require("utils.log").warn("book.dns no response", host, table.concat(Dns.servers(), ","))
            end
        end
        for _idx, waiter in ipairs(waiters) do waiter(addrs, err) end
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
