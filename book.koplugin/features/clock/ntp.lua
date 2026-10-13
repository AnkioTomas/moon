--[[--
SNTP（RFC 4330）客户端：发一个 48 字节请求，按回包四个时间戳算本机时钟偏差。

`query` 会解析域名、阻塞等 UDP 回包，只能在 workers.job 子进程里调；`offset` 是纯函数。

@module koplugin.book.features.clock.ntp
--]]

local Ntp = {}

--- NTP 纪元（1900-01-01）到 Unix 纪元的秒数。
local UNIX_EPOCH = 2208988800
local PORT = 123
--- LI=0、VN=3、Mode=3（客户端），其余全 0。
local REQUEST = string.char(0x1B) .. string.rep("\0", 47)

---@param data string
---@param i integer 时间戳首字节下标
---@return number unix 秒（带小数）
local function stamp(data, i)
    local a, b, c, d, e, f, g, h = data:byte(i, i + 7)
    local seconds = ((a * 256 + b) * 256 + c) * 256 + d
    -- 秒字段 2036 年回绕：最高位为 0 视为下一纪元（RFC 4330 §3）。
    if seconds < 0x80000000 then seconds = seconds + 0x100000000 end
    return seconds - UNIX_EPOCH + (((e * 256 + f) * 256 + g) * 256 + h) / 2 ^ 32
end

--- 服务器时间减本机时间（秒）；回包不是合法的服务器应答返回 nil。
---@param data string 回包
---@param sent number 发请求时的本机时间（unix 秒）
---@param received number 收到回包时的本机时间
---@return number|nil
function Ntp.offset(data, sent, received)
    if #data < 48 then return nil end
    local mode, stratum = data:byte(1) % 8, data:byte(2)
    -- stratum 0 是 Kiss-o'-Death（限流 / 拒绝），16 以上未同步。
    if mode ~= 4 or stratum < 1 or stratum > 15 then return nil end
    return ((stamp(data, 33) - sent) + (stamp(data, 41) - received)) / 2
end

--- 子进程里查询一次。
---@param server string 主机名或 IP
---@param timeout number 秒
---@return { offset: number|nil, err: string|nil }
function Ntp.query(server, timeout)
    local socket = require("socket")
    local udp = assert(socket.udp())
    udp:settimeout(timeout)
    local ok, err = udp:setpeername(server, PORT)
    if not ok then
        udp:close()
        return { err = "resolve: " .. tostring(err) }
    end
    local sent = socket.gettime()
    udp:send(REQUEST)
    local data
    data, err = udp:receive()
    local received = socket.gettime()
    udp:close()
    if not data then return { err = "receive: " .. tostring(err) } end
    local offset = Ntp.offset(data, sent, received)
    if not offset then return { err = "bad reply" } end
    return { offset = offset }
end

return Ntp
