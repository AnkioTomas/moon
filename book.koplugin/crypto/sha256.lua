--[[--
SHA-256。返回原始摘要；十六进制用 hex。

@module koplugin.book.crypto.sha256
--]]

local bit = require("bit")
local band, bxor, bnot = bit.band, bit.bxor, bit.bnot
local ror, rshift = bit.ror, bit.rshift

local Hex = require("crypto.hex")

local Sha256 = {}

local function is_prime(n)
    if n < 2 then return false end
    if n % 2 == 0 then return n == 2 end
    local i = 3
    while i * i <= n do
        if n % i == 0 then return false end
        i = i + 2
    end
    return true
end

-- 前 8 个素数的平方根小数部分、前 64 个素数的立方根小数部分。FIPS 180-4。
local H0, K = {}, {}
local prime = 2
while #H0 < 8 or #K < 64 do
    if is_prime(prime) then
        if #H0 < 8 then
            local root = math.sqrt(prime)
            H0[#H0 + 1] = math.floor((root - math.floor(root)) * 4294967296)
        end
        if #K < 64 then
            local root = prime ^ (1 / 3)
            K[#K + 1] = math.floor((root - math.floor(root)) * 4294967296)
        end
    end
    prime = prime + 1
end

local function u32(x)
    return x % 4294967296
end

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function put_be(x)
    x = u32(x)
    return string.char(
        math.floor(x / 16777216) % 256,
        math.floor(x / 65536) % 256,
        math.floor(x / 256) % 256,
        x % 256
    )
end

local function ch(x, y, z)
    return bxor(band(x, y), band(bnot(x), z))
end

local function maj(x, y, z)
    return bxor(band(x, y), band(x, z), band(y, z))
end

local function big0(x)
    return bxor(ror(x, 2), ror(x, 13), ror(x, 22))
end

local function big1(x)
    return bxor(ror(x, 6), ror(x, 11), ror(x, 25))
end

local function small0(x)
    return bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
end

local function small1(x)
    return bxor(ror(x, 17), ror(x, 19), rshift(x, 10))
end

---@param msg string
---@return string 32 字节
function Sha256.hash(msg)
    local bitlen = #msg * 8
    msg = msg .. "\128"
    while (#msg % 64) ~= 56 do
        msg = msg .. "\0"
    end
    local hi = math.floor(bitlen / 4294967296)
    local lo = bitlen % 4294967296
    msg = msg .. put_be(hi) .. put_be(lo)

    local h = {}
    for i = 1, 8 do h[i] = H0[i] end

    for off = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            w[i] = be32(msg, off + i * 4)
        end
        for i = 16, 63 do
            w[i] = u32(w[i - 16] + small0(w[i - 15]) + w[i - 7] + small1(w[i - 2]))
        end
        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 0, 63 do
            local t1 = u32(hh + big1(e) + ch(e, f, g) + K[i + 1] + w[i])
            local t2 = u32(big0(a) + maj(a, b, c))
            hh = g
            g = f
            f = e
            e = u32(d + t1)
            d = c
            c = b
            b = a
            a = u32(t1 + t2)
        end
        h[1] = u32(h[1] + a)
        h[2] = u32(h[2] + b)
        h[3] = u32(h[3] + c)
        h[4] = u32(h[4] + d)
        h[5] = u32(h[5] + e)
        h[6] = u32(h[6] + f)
        h[7] = u32(h[7] + g)
        h[8] = u32(h[8] + hh)
    end
    local out = {}
    for i = 1, 8 do out[i] = put_be(h[i]) end
    return table.concat(out)
end

---@param msg string
---@return string
function Sha256.hex(msg)
    return Hex.to_hex(Sha256.hash(msg))
end

return Sha256
