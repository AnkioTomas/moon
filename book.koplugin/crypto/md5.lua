--[[--
MD5。返回原始摘要；十六进制用 hex。

@module koplugin.book.crypto.md5
--]]

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rol = bit.rol

local Hex = require("crypto.hex")

local Md5 = {}

local S = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

-- T[i] = floor(2^32 * abs(sin(i)))，RFC 1321
local K = {}
for i = 1, 64 do
    K[i] = math.floor(4294967296 * math.abs(math.sin(i)))
end

local function u32(x)
    return x % 4294967296
end

local function F(x, y, z)
    return bxor(band(x, y), band(bnot(x), z))
end

local function G(x, y, z)
    return bxor(band(x, z), band(y, bnot(z)))
end

local function H(x, y, z)
    return bxor(x, y, z)
end

local function I(x, y, z)
    return bxor(y, bor(x, bnot(z)))
end

local function le32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((d * 256 + c) * 256 + b) * 256 + a
end

local function put_le(x)
    x = u32(x)
    return string.char(
        x % 256,
        math.floor(x / 256) % 256,
        math.floor(x / 65536) % 256,
        math.floor(x / 16777216) % 256
    )
end

---@param msg string
---@return string 16 字节
function Md5.hash(msg)
    local bitlen = #msg * 8
    msg = msg .. "\128"
    while (#msg % 64) ~= 56 do
        msg = msg .. "\0"
    end
    local lo = bitlen % 4294967296
    local hi = math.floor(bitlen / 4294967296)
    msg = msg .. put_le(lo) .. put_le(hi)

    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    for off = 1, #msg, 64 do
        local m = {}
        for i = 0, 15 do
            m[i] = le32(msg, off + i * 4)
        end
        local a, b, c, d = a0, b0, c0, d0
        for i = 1, 64 do
            local f, g
            local idx = i - 1
            if i <= 16 then
                f = F(b, c, d)
                g = idx
            elseif i <= 32 then
                f = G(b, c, d)
                g = (5 * idx + 1) % 16
            elseif i <= 48 then
                f = H(b, c, d)
                g = (3 * idx + 5) % 16
            else
                f = I(b, c, d)
                g = (7 * idx) % 16
            end
            local temp = u32(a + f + K[i] + m[g])
            a, b, c, d = d, u32(b + rol(temp, S[i])), b, c
        end
        a0 = u32(a0 + a)
        b0 = u32(b0 + b)
        c0 = u32(c0 + c)
        d0 = u32(d0 + d)
    end
    return put_le(a0) .. put_le(b0) .. put_le(c0) .. put_le(d0)
end

---@param msg string
---@return string
function Md5.hex(msg)
    return Hex.to_hex(Md5.hash(msg))
end

return Md5
