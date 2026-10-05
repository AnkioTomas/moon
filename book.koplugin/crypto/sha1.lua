--[[--
SHA-1。返回原始摘要；十六进制用 hex。

@module koplugin.book.crypto.sha1
--]]

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rol = bit.rol

local Hex = require("crypto.hex")

local Sha1 = {}

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

---@param msg string
---@return string 20 字节
function Sha1.hash(msg)
    local bitlen = #msg * 8
    msg = msg .. "\128"
    while (#msg % 64) ~= 56 do
        msg = msg .. "\0"
    end
    local hi = math.floor(bitlen / 4294967296)
    local lo = bitlen % 4294967296
    msg = msg .. put_be(hi) .. put_be(lo)

    local h0, h1, h2, h3, h4 =
        0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0

    for off = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            w[i] = be32(msg, off + i * 4)
        end
        for i = 16, 79 do
            w[i] = u32(rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1))
        end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then
                f = bor(band(b, c), band(bnot(b), d))
                k = 0x5A827999
            elseif i < 40 then
                f = bxor(b, c, d)
                k = 0x6ED9EBA1
            elseif i < 60 then
                f = bor(band(b, c), band(b, d), band(c, d))
                k = 0x8F1BBCDC
            else
                f = bxor(b, c, d)
                k = 0xCA62C1D6
            end
            local temp = u32(rol(a, 5) + f + e + k + w[i])
            e = d
            d = c
            c = u32(rol(b, 30))
            b = a
            a = temp
        end
        h0 = u32(h0 + a)
        h1 = u32(h1 + b)
        h2 = u32(h2 + c)
        h3 = u32(h3 + d)
        h4 = u32(h4 + e)
    end
    return put_be(h0) .. put_be(h1) .. put_be(h2) .. put_be(h3) .. put_be(h4)
end

---@param msg string
---@return string
function Sha1.hex(msg)
    return Hex.to_hex(Sha1.hash(msg))
end

return Sha1
