--[[-- http.dns：非阻塞 UDP 解析器——报文编解码、缓存、系统 + 备选竞速、超时失败记录、发不出去当场失败、备选选择。 --]]
---@diagnostic disable: undefined-field, inject-field, duplicate-set-field

local Assert = require("support.assert")
require("support.stubs")

-- 回调记成 a or false：nil 塞进数组等于没塞。
-- 自己的调度桩：poll 没结果会一直重排，Stubs.flush 跑到空队列会死循环；这里一次 tick 只跑一轮。
local queue = {}
package.loaded["ui/uimanager"] = { scheduleIn = function(_self, _delay, fn) queue[#queue + 1] = fn end }
local function tick()
    local batch = queue
    queue = {}
    for _idx, fn in ipairs(batch) do fn() end
end

-- 受控时钟 + 假 UDP：sendto 只记录（带所属 socket），收什么由用例往该 socket 的 inbox 喂。
local clock, sent, closed = 1000, {}, 0
local sendto_err, udp_err = nil, nil
local getaddrinfo_calls = {}
package.loaded["socket"] = nil
package.preload["socket"] = function()
    return {
        gettime = function() return clock end,
        udp = function()
            if udp_err then return nil, udp_err end
            local sock = { inbox = {} }
            function sock:settimeout(t) Assert.eq(t, 0, "UDP 必须零超时，不能阻塞 UI 线程") end
            function sock:sendto(packet, ip, port)
                sent[#sent + 1] = { packet = packet, ip = ip, port = port, sock = self }
                if sendto_err then return nil, sendto_err end
                return 1
            end
            function sock:receivefrom() return table.remove(self.inbox, 1) end
            function sock:close() closed = closed + 1 end
            return sock
        end,
        dns = { getaddrinfo = function(host)
            getaddrinfo_calls[#getaddrinfo_calls + 1] = host
            return { { addr = "9.9.9.9" } }
        end },
    }
end
local cfg = { http = {} }
package.preload["utils.settings"] = function()
    return { get = function(name) return cfg[name] end, save = function() end }
end
local now = 1700000000
os.time = function() return now end

local Dns = require("http.dns")

-- 真 FFI：libc 给的 nameserver 必须是 IPv4，且都在 resolv.conf 里（macOS / glibc 两边都从同一份配置生成）
do
    local libc = Dns.libcServers()
    local conf_set = {}
    local f = io.open("/etc/resolv.conf")
    if f then
        for line in f:lines() do
            local ip = line:match("^%s*nameserver%s+([%d%.]+)")
            if ip then conf_set[ip] = true end
        end
        f:close()
    end
    for _idx, ip in ipairs(libc) do
        Assert.matches(ip, "^%d+%.%d+%.%d+%.%d+$")
        if f then Assert.is_true(conf_set[ip], "libc 的 nameserver 不在 resolv.conf 里: " .. ip) end
    end
    Assert.eq(#Dns.libcServers(), #libc, "重复调用结果稳定")
end

-- Android：经 KOReader 的 JNI 桥取 ConnectivityManager 的 DNS（Java 对象用表模拟，方法名即键）
do
    local pending_exception = false
    local env = { [0] = {
        ExceptionCheck = function() return pending_exception and 1 or 0 end,
        ExceptionClear = function() pending_exception = false end,
        NewStringUTF = function(_env, s) return { jstring = s } end,
        DeleteLocalRef = function() end,
    } }
    local jni = { env = env }
    function jni:context(_vm, fn) return fn(self) end
    function jni:callObjectMethod(obj, method, _sig, arg)
        local f = obj[method]
        if type(f) == "function" then return f(arg) end
        return f
    end
    function jni:callIntMethod(obj, method) return obj[method] end
    function jni:to_string(js) return js.jstring end
    local function addr(ip) return { getHostAddress = { jstring = ip } } end
    local dns_list = { addr("fec0::3"), addr("10.0.2.3"), addr("10.0.2.4") }
    local list = { size = #dns_list, get = function(i) return dns_list[tonumber(i) + 1] end }
    local network = { tag = "network" }
    local cm = {
        getActiveNetwork = function() return network end,
        getLinkProperties = function(n) Assert.eq(n, network); return { getDnsServers = list } end,
    }
    local activity = { getSystemService = function(name) Assert.eq(name.jstring, "connectivity"); return cm end }
    package.loaded.android = { jni = jni, app = { activity = { clazz = activity, vm = {} } } }
    local fake_ffi = { cast = function(_t, v) return v end }

    Assert.eq(table.concat(Dns.androidServers(fake_ffi), ","), "10.0.2.3,10.0.2.4", "只取 IPv4，顺序照旧")

    cm.getActiveNetwork = function() return nil end
    Assert.eq(#Dns.androidServers(fake_ffi), 0, "没有活动网络（飞行模式）为空")

    cm.getActiveNetwork = function() pending_exception = true; return nil end
    Assert.eq(#Dns.androidServers(fake_ffi), 0, "Java 抛异常为空")
    Assert.is_false(pending_exception, "异常必须被清掉，否则下一次 JNI 调用崩进程")

    package.loaded.android = nil
    Assert.eq(#Dns.androidServers(fake_ffi), 0, "没有 android 桥为空")
end

-- 以下用例把 libc 桩成空、resolv.conf 指到不存在的文件：只剩备选，结果才可控
local libc_servers = {}
Dns.libcServers = function() return libc_servers end
Dns.RESOLV_CONF = os.tmpname() .. ".missing"

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
--- 组一条应答：和查询同 id，answers 为 { type, rdata } 列表，名字一律用压缩指针指回问题区。
local function reply(query, answers, rcode)
    local id = query:sub(1, 2)
    local qsection = query:sub(13)
    local parts = { id, string.char(0x81, 0x80 + (rcode or 0)), u16(1), u16(#answers), u16(0), u16(0), qsection }
    for _idx, a in ipairs(answers) do
        parts[#parts + 1] = "\xC0\x0C" .. u16(a[1]) .. u16(1) .. "\0\0\0\60" .. u16(#a[2]) .. a[2]
    end
    return table.concat(parts)
end
--- 把应答投进发出该查询的 socket。
local function answer(entry, answers, rcode)
    entry.sock.inbox[#entry.sock.inbox + 1] = reply(entry.packet, answers, rcode)
end

-- 编码：标准 A 查询，RD 置位
local q = Dns.encode("api.ankio.net", 0x1234)
Assert.eq(q:sub(1, 2), "\x12\x34")
Assert.eq(q:sub(3, 4), "\1\0", "递归期望")
Assert.eq(q:sub(13), "\3api\5ankio\3net\0\0\1\0\1")

-- 解码：CNAME 在前、A 在后（含压缩指针），取到 A；id 不对 / 不是应答 → mismatch；NXDOMAIN；没有 A
local addr = Dns.decode(reply(q, { { 5, "\3cdn\0" }, { 1, "\1\2\3\4" } }), 0x1234)
Assert.eq(addr, "1.2.3.4")
local _nil, err = Dns.decode(reply(q, { { 1, "\1\2\3\4" } }), 0x9999)
Assert.eq(err, "mismatch")
_nil, err = Dns.decode(q, 0x1234)
Assert.eq(err, "mismatch", "自己的查询回环不算应答")
_nil, err = Dns.decode(reply(q, {}, 3), 0x1234)
Assert.eq(err, "nxdomain")
_nil, err = Dns.decode(reply(q, { { 28, string.rep("\0", 16) } }), 0x1234)
Assert.eq(err, "noanswer", "只有 AAAA 没有 A")
_nil, err = Dns.decode("\x12\x34\x81", 0x1234)
Assert.eq(err, "mismatch", "截断报文不崩")

-- 备选：默认阿里；设置选腾讯；未知值（含旧的 "system"）回默认
Assert.eq(Dns.current().id, "ali")
Assert.eq(#Dns.servers(), 2); Assert.eq(Dns.servers()[1], "223.5.5.5")
cfg.http.dns = "tencent"
Assert.eq(Dns.servers()[1], "119.29.29.29")
cfg.http.dns = "system"
Assert.eq(Dns.current().id, "ali")
cfg.http.dns = nil

-- 解析：IP 字面量同步回，不发包
local got = {}
Dns.resolve("1.2.3.4", function(a) got[#got + 1] = a or false end)
Dns.resolve("2001:db8::1", function(a) got[#got + 1] = a or false end)
Assert.eq(got[1], "1.2.3.4"); Assert.eq(got[2], "2001:db8::1"); Assert.eq(#sent, 0)

-- 主机名：同一个包同时发给两台，谁先答用谁；同主机并发只查一次；应答到了一起回；之后命中缓存
got = {}
Dns.resolve("img.example.com", function(a) got[#got + 1] = a or false end)
Dns.resolve("img.example.com", function(a) got[#got + 1] = a or false end)
Assert.eq(#sent, 2, "同主机并发只查一次，一次同时问全部服务器")
Assert.eq(sent[1].ip, "223.5.5.5"); Assert.eq(sent[2].ip, "223.6.6.6"); Assert.eq(sent[1].port, 53)
Assert.eq(sent[1].packet, sent[2].packet, "同一个查询（同 id）")
Assert.eq(sent[1].sock, sent[2].sock, "同一个 socket 收所有应答")
Assert.eq(#got, 0, "应答没到不回调")
answer(sent[2], { { 1, "\10\0\0\1" } })
tick()
Assert.eq(#got, 2); Assert.eq(got[1], "10.0.0.1"); Assert.eq(got[2], "10.0.0.1")
Assert.eq(closed, 1, "查完关 socket")
Dns.resolve("img.example.com", function(a) got[#got + 1] = a or false end)
Assert.eq(got[3], "10.0.0.1"); Assert.eq(#sent, 2, "缓存命中不发包")

-- 别人的应答（id 不符）忽略，继续等
sent, got = {}, {}
Dns.resolve("a.example.com", function(a) got[#got + 1] = a or false end)
sent[1].sock.inbox[1] = reply(Dns.encode("a.example.com", 1), { { 1, "\7\7\7\7" } })
tick()
Assert.eq(#got, 0, "id 不符的应答不能当结果")
answer(sent[1], { { 1, "\8\8\8\8" } })
tick()
Assert.eq(got[1], "8.8.8.8")

-- 全部服务器 QUERY_TIMEOUT 内没应答：回 nil, "timeout"；同主机 FAIL_TTL 内直接 nil 不发包
sent, got = {}, {}
local errs = {}
Dns.resolve("dead.example.com", function(a, e) got[#got + 1] = a or false; errs[#errs + 1] = e end)
Assert.eq(#sent, 2)
tick()
Assert.eq(#got, 0, "没到超时不放弃")
clock = clock + Dns.QUERY_TIMEOUT + 0.01
tick()
Assert.eq(#got, 1); Assert.eq(got[1], false); Assert.eq(errs[1], "timeout"); Assert.eq(#sent, 2, "超时不重发")
Dns.resolve("dead.example.com", function(a, e) got[#got + 1] = a or false; errs[#errs + 1] = e end)
Assert.eq(#got, 2); Assert.eq(got[2], false); Assert.eq(errs[2], "failed recently"); Assert.eq(#sent, 2, "失败记录内不再发包")
-- drop 只丢地址缓存不丢失败记录；forget 两者都清；失败记录 FAIL_TTL 秒后过期
Dns.drop("dead.example.com")
Dns.resolve("dead.example.com", function(a) got[#got + 1] = a or false end)
Assert.eq(#sent, 2, "drop 不清失败记录")
Dns.forget("dead.example.com")
Dns.resolve("dead.example.com", function(a) got[#got + 1] = a or false end)
Assert.eq(#sent, 4, "forget 后重新查")
Dns.clear()
sent = {}
Dns.resolve("dead.example.com", function() end)
clock = clock + Dns.QUERY_TIMEOUT + 0.01
tick()
now = now + Dns.FAIL_TTL + 1
Dns.resolve("dead.example.com", function() end)
Assert.eq(#sent, 4, "失败记录到期后重新发包")

-- NXDOMAIN：先到的服务器答了「没有」就定了，立刻回 nil, "nxdomain"
sent, got, errs = {}, {}, {}
Dns.resolve("nx.invalid", function(a, e) got[#got + 1] = a or false; errs[#errs + 1] = e end)
answer(sent[1], {}, 3)
tick()
Assert.eq(#got, 1); Assert.eq(got[1], false); Assert.eq(errs[1], "nxdomain")

-- SERVFAIL（路由器 dnsmasq 上游断了秒回）不定局：继续等别的服务器，第二台答了地址就用
sent, got, errs = {}, {}, {}
Dns.resolve("sf.example.com", function(a, e) got[#got + 1] = a or false; errs[#errs + 1] = e end)
answer(sent[1], {}, 2)
tick()
Assert.eq(#got, 0, "一个 SERVFAIL 不能让备选 DNS 白配")
answer(sent[2], { { 1, "\9\9\9\9" } })
tick()
Assert.eq(got[1], "9.9.9.9")
-- 全部服务器都答 SERVFAIL / REFUSED：不等到超时，按最后一个错立即回
sent, got, errs = {}, {}, {}
Dns.resolve("sf2.example.com", function(a, e) got[#got + 1] = a or false; errs[#errs + 1] = e end)
answer(sent[1], {}, 2)
answer(sent[2], {}, 5)
tick()
Assert.eq(#got, 1); Assert.eq(got[1], false); Assert.eq(errs[1], "rcode 5")
-- 一台 SERVFAIL、另一台到超时都没应答：按超时前记下的错回
sent, got, errs = {}, {}, {}
Dns.resolve("sf3.example.com", function(a, e) got[#got + 1] = a or false; errs[#errs + 1] = e end)
answer(sent[1], {}, 2)
tick()
Assert.eq(#got, 0)
clock = clock + Dns.QUERY_TIMEOUT + 0.01
tick()
Assert.eq(#got, 1); Assert.eq(errs[1], "rcode 2")

-- /etc/hosts：静态条目优先于 UDP 查询（大小写不敏感、带注释、多名字一行），命中后进缓存
local hosts = os.tmpname()
local hf = assert(io.open(hosts, "w"))
hf:write("# comment\n127.0.0.1 localhost\n192.168.1.20   nas.lan  Books.Home # my nas\n::1 ip6-localhost\n")
hf:close()
Dns.HOSTS = hosts
sent, got = {}, {}
Dns.resolve("books.home", function(a) got[#got + 1] = a or false end)
Assert.eq(got[1], "192.168.1.20"); Assert.eq(#sent, 0, "hosts 命中不发包")
Dns.resolve("ip6-localhost", function(a) got[#got + 1] = a or false end)
Assert.eq(#sent, 2, "只认 IPv4 行，其余照常查")
os.remove(hosts)
Dns.HOSTS = hosts .. ".missing"
Assert.is_nil(Dns.hostsLookup("nas.lan"), "没有 hosts 文件不崩")

-- 缓存 TTL 到期重查
now = now + Dns.TTL + 1
sent = {}
Dns.resolve("img.example.com", function() end)
Assert.eq(#sent, 2, "缓存过期重新发包")

-- 系统 DNS：libc 给的排在备选前面一起问，与备选重复的去重；系统先答就用系统的
Dns.clear()
libc_servers = { "192.168.1.1", "223.5.5.5" }
local servers = Dns.servers()
Assert.eq(#servers, 3, "与备选重复的去重")
Assert.eq(servers[1], "192.168.1.1"); Assert.eq(servers[2], "223.5.5.5"); Assert.eq(servers[3], "223.6.6.6")
sent, got = {}, {}
Dns.resolve("sys.example.com", function(a) got[#got + 1] = a or false end)
Assert.eq(#sent, 3, "系统 + 备选同时问")
Assert.eq(sent[1].ip, "192.168.1.1")
answer(sent[1], { { 1, "\192\168\1\50" } })
answer(sent[3], { { 1, "\1\1\1\1" } })
tick()
Assert.eq(got[1], "192.168.1.50", "先到的应答定结果")

-- libc 拿不到（musl）：退回 resolv.conf，IPv6 跳过；文件也没有（Android）只剩备选
libc_servers = {}
Dns.clear()
local conf = os.tmpname()
local f = assert(io.open(conf, "w"))
f:write("# generated\nsearch lan\nnameserver 10.0.0.1\nnameserver fe80::1\n")
f:close()
Dns.RESOLV_CONF = conf
Assert.eq(table.concat(Dns.systemServers(), ","), "10.0.0.1")
os.remove(conf)
Dns.RESOLV_CONF = conf .. ".missing"
Assert.eq(#Dns.servers(), 2, "没有 resolv.conf（Android）只剩备选")
Assert.eq(#getaddrinfo_calls, 0, "任何路径都不碰同步 getaddrinfo")

-- 没网：sendto 立即失败，当场同步回 nil + 原因，不等、不排 poll、不记失败（网一回来下次就能查）
cfg.http.dns = nil
Dns.clear()
sent, got, errs, sendto_err = {}, {}, {}, "Network is unreachable"
local q0, c0 = #queue, closed
Dns.resolve("offline.example.com", function(a, e) got[#got + 1] = a or false; errs[#errs + 1] = e end)
Assert.eq(#sent, 2, "两台都试过"); Assert.eq(#got, 1); Assert.eq(got[1], false)
Assert.matches(errs[1], "^sendto Network is unreachable"); Assert.eq(#queue, q0, "一个都发不出去，不排 poll")
Assert.eq(closed, c0 + 1, "发不出去也关 socket")
sendto_err = nil
sent = {}
Dns.resolve("offline.example.com", function() end)
Assert.eq(#sent, 2, "没网那次不记失败，网回来立刻重查")
-- 建不出 socket 同理：当场回 nil，不留 pending
Dns.clear()
udp_err, got, errs = "Too many open files", {}, {}
Dns.resolve("nofd.example.com", function(a, e) got[#got + 1] = a or false; errs[#errs + 1] = e end)
Assert.eq(#got, 1); Assert.eq(got[1], false); Assert.matches(errs[1], "^socket Too many open files")
udp_err = nil
sent = {}
Dns.resolve("nofd.example.com", function() end)
Assert.eq(#sent, 2, "失败不留 pending、不记失败，下一次直接重新查")

-- 换备选 clear：缓存、失败记录全清
cfg.http.dns = nil
Dns.clear()
sent = {}
Dns.resolve("img.example.com", function() end)
Assert.eq(#sent, 2, "clear 后重新解析")

package.preload["socket"], package.loaded["socket"] = nil, nil
package.preload["utils.settings"], package.loaded["utils.settings"] = nil, nil
package.loaded["http.dns"] = nil
package.loaded["ui/uimanager"] = nil
