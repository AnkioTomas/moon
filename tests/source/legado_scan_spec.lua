--[[--
阅读 App 换 IP：网段枚举、书架回包、失败分类，以及非阻塞端口扫描。

@module tests.source.legado_scan_spec
--]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")
local JSONStub = require("support.json_stub")
local Stubs = require("support.stubs")

package.loaded["json"] = { decode = JSONStub.decode, encode = JSONStub.encode }

local cfg = { server_address = "http://192.168.1.8:1122" }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end,
    saveSource = function() end,
}
package.loaded["source.legado.client"] = {
    mode = function()
        local base = cfg.server_address or ""
        if base:find("/reader3", 1, true) then return "reader3" end
        if base:find("/api/%d+$") then return "qread" end
        return "app"
    end,
    base = function()
        local addr = cfg.server_address
        if type(addr) ~= "string" or addr == "" then return nil end
        if not addr:match("^https?://") then addr = "http://" .. addr end
        return (addr:gsub("/+$", ""))
    end,
}

local tcp_count = 0
local now = 1000
local no_ip = false
local open_at = {}
local blackhole = {}
local immediate = false
local requests = {}

local function installNet()
    package.loaded["socket"] = {
        udp = function()
            return {
                setpeername = function()
                    if no_ip then return nil end
                    return 1
                end,
                getsockname = function() return "192.168.1.50", 1 end,
                close = function() end,
            }
        end,
        tcp = function()
            tcp_count = tcp_count + 1
            local sock = {}
            function sock:settimeout() end
            function sock:close() self.closed = true end
            function sock:connect(host, port)
                self.host, self.port = host, port
                if self.tried then
                    if open_at[host] then return 1 end
                    return nil, "connection refused"
                end
                self.tried = true
                if immediate then return 1 end
                if open_at[host] or blackhole[host] then
                    self.open = open_at[host] == true
                    return nil, "timeout"
                end
                return nil, "connection refused"
            end
            return sock
        end,
        select = function(_recv, sendt)
            local ready = {}
            for _idx, sock in ipairs(sendt or {}) do
                if sock.open then ready[#ready + 1] = sock end
            end
            if #ready == 0 then now = now + 1 end
            return {}, ready
        end,
        gettime = function() return now end,
    }
    package.loaded["http.request"] = {
        get = function(url, _opts, cb)
            requests[#requests + 1] = url
            local body = url:find("192.168.1.9:", 1, true)
                and '{"isSuccess":true,"errorMsg":"","data":[{"bookUrl":"u"}]}'
                or "<html>"
            cb(body)
            return { cancel = function() end }
        end,
    }
end

installNet()
package.loaded["source.legado.scan"] = nil
local Scan = require("source.legado.scan")

local function resetScan()
    tcp_count = 0
    now = 1000
    no_ip = false
    open_at = {}
    blackhole = {}
    immediate = false
    requests = {}
    cfg.server_address = "http://192.168.1.8:1122"
end

-- 网段：去掉自己和网络号 / 广播，254 - 1 = 253。
do
    local hosts = Scan.hosts("192.168.1.50")
    Assert.eq(#hosts, 253)
    Assert.eq(hosts[1], "192.168.1.1")
    Assert.eq(hosts[49], "192.168.1.49")
    Assert.eq(hosts[50], "192.168.1.51")
    Assert.eq(hosts[253], "192.168.1.254")
    Assert.eq(#Scan.hosts("0.1.1.1"), 0)
    Assert.eq(#Scan.hosts("999.1.1.1"), 0)
    Assert.eq(#Scan.hosts("phone.lan"), 0)
end

-- 只有书架形状的回包算命中。
do
    Assert.is_true(Scan.isShelf('{"isSuccess":true,"errorMsg":"","data":[]}'))
    Assert.is_true(Scan.isShelf('{"isSuccess":true,"errorMsg":"","data":[{"bookUrl":"u"}]}'))
    Assert.is_false(Scan.isShelf('{"isSuccess":true,"errorMsg":"","data":{"a":1}}'))
    Assert.is_false(Scan.isShelf('{"isSuccess":true,"errorMsg":"","data":["x"]}'))
    Assert.is_false(Scan.isShelf('{"isSuccess":false,"errorMsg":"x","data":[]}'))
    Assert.is_false(Scan.isShelf('{"isSuccess":true,"data":[]}'))
    Assert.is_false(Scan.isShelf("<html>"))
    Assert.is_false(Scan.isShelf(nil))
end

-- 本机地址来自路由表。没有路由就扫不了。
do
    resetScan()
    Assert.eq(Scan.localIP(), "192.168.1.50")
    no_ip = true
    Assert.is_nil(Scan.localIP())
end

-- 一台端口通且回包是书架：只校验这一台。
do
    resetScan()
    open_at["192.168.1.9"] = true
    local found, err
    Scan.find(function(list, reason) found, err = list, reason end)
    Stubs.flush()
    Assert.is_nil(err)
    Assert.len(found, 1)
    Assert.eq(found[1], "http://192.168.1.9:1122")
    Assert.len(requests, 1)
    Assert.eq(requests[1], "http://192.168.1.9:1122/getBookshelf?refresh=0")
end

-- 保存的端口不是 1122 时，探测和结果都用这个端口。
do
    resetScan()
    cfg.server_address = "http://192.168.1.8:1234"
    open_at["192.168.1.9"] = true
    local found
    Scan.find(function(list) found = list end)
    Stubs.flush()
    Assert.eq(found[1], "http://192.168.1.9:1234")
    Assert.eq(requests[1], "http://192.168.1.9:1234/getBookshelf?refresh=0")
    cfg.server_address = "http://192.168.1.8:1122"
end

-- 回包不像书架的端口丢掉。
do
    resetScan()
    open_at["192.168.1.10"] = true
    open_at["192.168.1.9"] = true
    package.loaded["http.request"].get = function(url, _opts, cb)
        requests[#requests + 1] = url
        local host = url:match("http://([^:]+)")
        local body = host == "192.168.1.10"
            and '<html>'
            or '{"isSuccess":true,"errorMsg":"","data":[{"bookUrl":"u"}]}'
        cb(body)
        return { cancel = function() end }
    end
    local found
    Scan.find(function(list) found = list end)
    Stubs.flush()
    Assert.len(found, 1)
    Assert.eq(found[1], "http://192.168.1.9:1122")
end

-- 没有阅读服务。端口全通（多于 8 台）不当成结果，也不发 HTTP。
do
    resetScan()
    local found
    Scan.find(function(list) found = list end)
    Stubs.flush()
    Assert.len(found, 0)
    Assert.len(requests, 0)

    resetScan()
    immediate = true
    Scan.find(function(list) found = list end)
    Stubs.flush()
    Assert.len(found, 0)
    Assert.len(requests, 0)
end

-- 没路由：不探端口。
do
    resetScan()
    no_ip = true
    local found, err
    Scan.find(function(list, reason) found, err = list, reason end)
    Stubs.flush()
    Assert.is_nil(found)
    Assert.eq(err, "no-ip")
    Assert.eq(tcp_count, 0)
end

-- 取消后不再回调，也还没探端口。
do
    resetScan()
    local called = false
    local handle = Scan.find(function() called = true end)
    handle.cancel()
    Stubs.flush()
    Assert.is_false(called)
    Assert.eq(tcp_count, 0)
end

-- 黑掉的地址等到超时就丢掉，不发 HTTP。
do
    resetScan()
    blackhole["192.168.1.9"] = true
    local found
    Scan.find(function(list) found = list end)
    Stubs.flush()
    Assert.len(found, 0)
    Assert.len(requests, 0)
end
