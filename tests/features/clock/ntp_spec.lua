--[[--
clock.ntp：回包校验与偏差计算（含 2036 年秒字段回绕）。
@module tests.features.clock.ntp_spec
--]]

local Assert = require("support.assert")
local Ntp = require("features.clock.ntp")

local UNIX_EPOCH = 2208988800

--- 8 字节 NTP 时间戳。
---@param unix number
local function stamp(unix)
    local ntp = unix + UNIX_EPOCH
    local seconds = math.floor(ntp) % 0x100000000
    local fraction = math.floor((ntp - math.floor(ntp)) * 2 ^ 32)
    local out = {}
    for _idx, value in ipairs({ seconds, fraction }) do
        out[#out + 1] = string.char(math.floor(value / 2 ^ 24) % 256, math.floor(value / 2 ^ 16) % 256,
            math.floor(value / 2 ^ 8) % 256, value % 256)
    end
    return table.concat(out)
end

---@param first integer 首字节（LI/VN/Mode）
---@param stratum integer
---@param recv number 服务器收到请求的时间
---@param xmit number 服务器发回包的时间
local function reply(first, stratum, recv, xmit)
    return string.char(first, stratum) .. string.rep("\0", 30) .. stamp(recv) .. stamp(xmit)
end

-- 服务器比本机快 100 秒，往返各 0.2 秒
do
    local sent = 1700000000
    local data = reply(0x24, 2, sent + 100.2, sent + 100.3)
    local offset = Ntp.offset(data, sent, sent + 0.5)
    Assert.is_true(math.abs(offset - 100) < 1e-3, "偏差约 100 秒: " .. tostring(offset))
end

-- 本机慢了一整年（电池耗尽回到旧时间）：偏差为正的大数
do
    local real = 1790000000
    local offset = Ntp.offset(reply(0x24, 1, real, real), real - 365 * 86400, real - 365 * 86400)
    Assert.is_true(math.abs(offset - 365 * 86400) < 1e-3)
end

-- 2036-02-07 之后秒字段回绕到小数值，仍要算对
do
    local after = 2085978496 + 1000 -- 2036 回绕点之后
    local offset = Ntp.offset(reply(0x24, 2, after, after), after, after)
    Assert.is_true(math.abs(offset) < 1e-3, "回绕后偏差应为 0: " .. tostring(offset))
end

-- 非法回包
do
    local now = 1700000000
    Assert.is_nil(Ntp.offset("short", now, now), "不足 48 字节")
    Assert.is_nil(Ntp.offset(reply(0x23, 2, now, now), now, now), "mode 3 不是服务器应答")
    Assert.is_nil(Ntp.offset(reply(0x24, 0, now, now), now, now), "stratum 0 是 Kiss-o'-Death")
    Assert.is_nil(Ntp.offset(reply(0x24, 16, now, now), now, now), "stratum 16 未同步")
end
