--[[--
HKDF-SHA256 与 AES-GCM 解密（浏览器扩展 moon-cookie-storage 的加密信封，见 features/cookie）。

只做解密：密钥 16/24/32 字节，IV 12 字节，GCM 标签 16 字节、拼在密文末尾；标签不符返回 nil。

@module koplugin.book.crypto.gcm
--]]

local bit = require("bit")
local Aes = require("crypto.aes")
local sha2 = require("ffi/sha2")

local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local Gcm = {}

---@param key string
---@param msg string
---@return string 原始 32 字节
local function hmac(key, msg)
    return sha2.hex_to_bin(sha2.hmac(sha2.sha256, key, msg))
end

--- HKDF-SHA256，最多 32 字节（一个输出块，够 AES-256 密钥）。
---@param ikm string
---@param salt string
---@param info string
---@param length integer
---@return string
function Gcm.hkdf(ikm, salt, info, length)
    assert(length <= 32, "hkdf: one block only")
    return hmac(hmac(salt, ikm), info .. "\1"):sub(1, length)
end

---@param s string 16 字节
---@return integer[] 4 个大端 32 位字
local function words(s)
    local w = {}
    for i = 0, 3 do
        local a, b, c, d = s:byte(i * 4 + 1, i * 4 + 4)
        w[i + 1] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    return w
end

---@param w integer[]
---@return string
local function bytes(w)
    local out = {}
    for i = 1, 4 do
        local x = w[i]
        out[i] = string.char(band(rshift(x, 24), 255), band(rshift(x, 16), 255), band(rshift(x, 8), 255), band(x, 255))
    end
    return table.concat(out)
end

--- GF(2^128) 乘法（GCM 比特序）。
local function gmul(x, h)
    local z0, z1, z2, z3 = 0, 0, 0, 0
    local v0, v1, v2, v3 = h[1], h[2], h[3], h[4]
    for i = 1, 4 do
        local xi = x[i]
        for b = 31, 0, -1 do
            if band(rshift(xi, b), 1) == 1 then
                z0, z1, z2, z3 = bxor(z0, v0), bxor(z1, v1), bxor(z2, v2), bxor(z3, v3)
            end
            local lsb = band(v3, 1)
            v3 = bor(rshift(v3, 1), lshift(band(v2, 1), 31))
            v2 = bor(rshift(v2, 1), lshift(band(v1, 1), 31))
            v1 = bor(rshift(v1, 1), lshift(band(v0, 1), 31))
            v0 = rshift(v0, 1)
            if lsb == 1 then v0 = bxor(v0, 0xE1000000) end
        end
    end
    return { z0, z1, z2, z3 }
end

--- GHASH 吃一段数据，末块补零。
local function absorb(y, h, data)
    for i = 1, #data, 16 do
        local block = data:sub(i, i + 15)
        block = block .. string.rep("\0", 16 - #block)
        local w = words(block)
        y = gmul({ bxor(y[1], w[1]), bxor(y[2], w[2]), bxor(y[3], w[3]), bxor(y[4], w[4]) }, h)
    end
    return y
end

---@param n integer 位数（本模块只处理 < 2^32）
---@return string 8 字节大端
local function len64(n)
    return "\0\0\0\0" .. string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
end

---@param key string
---@param iv string 12 字节
---@param aad string
---@param sealed string 密文 .. 16 字节标签
---@return string|nil plain 标签校验失败为 nil
function Gcm.decrypt(key, iv, aad, sealed)
    if #iv ~= 12 or #sealed < 16 then return nil end
    local ct, tag = sealed:sub(1, -17), sealed:sub(-16)
    local h = words(Aes.ecb_encrypt(string.rep("\0", 16), key, false))

    local y = absorb({ 0, 0, 0, 0 }, h, aad)
    y = absorb(y, h, ct)
    y = absorb(y, h, len64(#aad * 8) .. len64(#ct * 8))

    local blocks = math.ceil(#ct / 16)
    local counters = {}
    for i = 1, blocks + 1 do
        counters[i] = iv .. string.char(band(rshift(i, 24), 255), band(rshift(i, 16), 255), band(rshift(i, 8), 255), band(i, 255))
    end
    local stream = Aes.ecb_encrypt(table.concat(counters), key, false)

    local expected = {}
    local ghash, mask = bytes(y), stream:sub(1, 16)
    for i = 1, 16 do expected[i] = string.char(bxor(ghash:byte(i), mask:byte(i))) end
    local diff = 0
    for i = 1, 16 do diff = bor(diff, bxor(table.concat(expected):byte(i), tag:byte(i))) end
    if diff ~= 0 then return nil end

    local plain = {}
    for i = 1, #ct do
        plain[i] = string.char(bxor(ct:byte(i), stream:byte(16 + i)))
    end
    return table.concat(plain)
end

--- 只解 CTR 流、不校验标签：96 位 IV 的 GCM 密文就是从计数器 2 起的 CTR 流。
--- 用于番茄漫画页图（几百 KB 一张），纯 Lua 的 GHASH 在墨水屏上太慢；图片的完整性由后续按文件头识别图片兜底。
---@param key string
---@param iv string 12 字节
---@param ct string 密文（不含标签）
---@return string
function Gcm.ctr(key, iv, ct)
    local counters = {}
    for i = 1, math.ceil(#ct / 16) do
        local n = i + 1
        counters[i] = iv .. string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
    end
    local stream = Aes.ecb_encrypt(table.concat(counters), key, false)
    local plain = {}
    for i = 1, #ct do
        plain[i] = string.char(bxor(ct:byte(i), stream:byte(i)))
    end
    return table.concat(plain)
end

return Gcm
