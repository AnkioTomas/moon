--[[--
手动扫描局域网里的阅读 App Web 服务。

阅读不广播自己。只扫本机所在的 IPv4 /24，只探已经保存的端口（没配过就是 1122），
端口通了再拉一次 /getBookshelf，回包长得像书架才算。

@module koplugin.book.source.legado.scan
--]]

local Scan = {}

local DEFAULT_PORT = 1122
local PARALLEL = 32
local CONNECT_TIMEOUT = 0.6
local POLL = 0.05
-- 家用网段里阅读服务就一两台。端口全通是网关在假装连上，再打 HTTP 没有意义。
local MAX_OPEN = 8

---@param ip string
---@return string[]
function Scan.hosts(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not a or a > 255 or b > 255 or c > 255 or d > 255 or a == 0 then return {} end
    local prefix = string.format("%d.%d.%d.", a, b, c)
    local hosts = {}
    for octet = 1, 254 do
        if octet ~= d then hosts[#hosts + 1] = prefix .. octet end
    end
    return hosts
end

--- 本机出口 IPv4。UDP setpeername 只查路由，不发包。
---@return string|nil
function Scan.localIP()
    local udp = require("socket").udp()
    if not udp then return nil end
    local ip
    if udp:setpeername("203.0.113.1", "53") then
        ip = udp:getsockname()
    end
    udp:close()
    if type(ip) ~= "string" or #Scan.hosts(ip) == 0 then return nil end
    return ip
end

--- 已保存的阅读 App 端口；没配过或不是 App 地址就用默认端口。
---@return integer
local function savedPort()
    local Client = require("source.legado.client")
    local base = Client.mode() == "app" and Client.base()
    local port = tonumber(base and base:match("^https?://[^/:]+:(%d+)$"))
    return port and port >= 1 and port <= 65535 and port or DEFAULT_PORT
end

--- `{ isSuccess, errorMsg, data: [] | [book, ...] }`。对象塞在 data 里不算书架。
---@param raw string|nil
---@return boolean
function Scan.isShelf(raw)
    if type(raw) ~= "string" or raw == "" then return false end
    local ok, wire = pcall(require("json").decode, raw)
    if not ok or type(wire) ~= "table" or wire.isSuccess ~= true or type(wire.errorMsg) ~= "string" then
        return false
    end
    if type(wire.data) ~= "table" then return false end
    if wire.data[1] ~= nil then return type(wire.data[1]) == "table" end
    return next(wire.data) == nil
end

---@param current table
local function abort(current)
    current.cancelled = true
    require("ui/uimanager"):unschedule(current.poll)
    for _idx, item in ipairs(current.pending) do item.sock:close() end
    for _idx, job in ipairs(current.jobs) do job.cancel() end
end

local function take(current)
    local socket = current.socket
    while #current.pending < PARALLEL and current.cursor <= #current.hosts do
        local host = current.hosts[current.cursor]
        current.cursor = current.cursor + 1
        local sock = socket.tcp()
        if not sock then
            current.cursor = #current.hosts + 1
            return
        end
        sock:settimeout(0)
        local ok, err = sock:connect(host, current.port)
        if ok or err == "already connected" then
            sock:close()
            current.open[#current.open + 1] = host
        elseif err == "timeout" then
            current.pending[#current.pending + 1] = {
                sock = sock, host = host, deadline = socket.gettime() + CONNECT_TIMEOUT,
            }
        else
            sock:close()
        end
    end
end

local function reap(current)
    if #current.pending == 0 then return end
    local socks = {}
    for idx, item in ipairs(current.pending) do socks[idx] = item.sock end
    local _recv, writable = current.socket.select({}, socks, 0)
    if type(writable) ~= "table" then writable = {} end
    local ready = {}
    for _idx, sock in ipairs(writable) do ready[sock] = true end
    local now = current.socket.gettime()
    local left = {}
    for _idx, item in ipairs(current.pending) do
        if ready[item.sock] then
            local ok, err = item.sock:connect(item.host, current.port)
            item.sock:close()
            if ok or err == "already connected" then
                current.open[#current.open + 1] = item.host
            end
        elseif now >= item.deadline then
            item.sock:close()
        else
            left[#left + 1] = item
        end
    end
    current.pending = left
end

local function verify(current)
    if #current.open == 0 or #current.open > MAX_OPEN then
        current.cb({})
        return
    end
    local Timeout = require("http.timeout")
    local Request = require("http.request")
    local left = #current.open
    local found = {}
    for _idx, host in ipairs(current.open) do
        local address = "http://" .. host .. ":" .. current.port
        current.jobs[#current.jobs + 1] = Request.get(address .. "/getBookshelf?refresh=0", {
            accept = "application/json",
            timeout = Timeout.net(0.1),
            connect_timeout = Timeout.net(0.05),
        }, function(raw)
            if current.cancelled then return end
            if Scan.isShelf(raw) then found[#found + 1] = address end
            left = left - 1
            if left == 0 then current.cb(found) end
        end)
    end
end

--- 扫完回调 `cb(addresses)` 或 `cb(nil, "no-ip")`。回调一定在返回之后；取消后不再回调。
---@param cb fun(found: string[]|nil, err: string|nil)
---@return { cancel: fun() }
function Scan.find(cb)
    local UIManager = require("ui/uimanager")
    local ip = Scan.localIP()
    local current = {
        cb = cb,
        pending = {},
        open = {},
        jobs = {},
        hosts = ip and Scan.hosts(ip) or {},
        cursor = 1,
        port = savedPort(),
        socket = require("socket"),
    }
    function current.poll()
        if current.cancelled then return end
        reap(current)
        take(current)
        if #current.pending > 0 or current.cursor <= #current.hosts then
            UIManager:scheduleIn(POLL, current.poll)
        else
            verify(current)
        end
    end
    if ip then
        UIManager:scheduleIn(POLL, current.poll)
    else
        UIManager:nextTick(function()
            if not current.cancelled then cb(nil, "no-ip") end
        end)
    end
    return { cancel = function() abort(current) end }
end

return Scan
