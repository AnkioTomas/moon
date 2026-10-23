--[[--
DES-CBC / PKCS7 / Base64（纯 Lua，不依赖原生库）。

晋江 App 接口的登录密码、签名与已购章节正文都用它加解密（密钥写死在 App 里）。
数据量小（密码十几字节、一章几 KB），位数组实现够用；解密大章请放子进程。

@module koplugin.book.source.jjwxc.des
--]]

local bit = require("bit")

local Des = {}

local IP = {
    58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6, 64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7,
}
local FP = {
    40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30, 37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25,
}
local E = {
    32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11,
    12, 13, 12, 13, 14, 15, 16, 17, 16, 17, 18, 19, 20, 21, 20, 21,
    22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1,
}
local P = {
    16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
    2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25,
}
local PC1 = {
    57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18,
    10, 2, 59, 51, 43, 35, 27, 19, 11, 3, 60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22,
    14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 28, 20, 12, 4,
}
local PC2 = {
    14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10,
    23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
    41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32,
}
local SHIFTS = { 1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1 }
local SBOX = {
    { 14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
      0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
      4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
      15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13 },
    { 15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
      3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
      0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
      13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9 },
    { 10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
      13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
      13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
      1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12 },
    { 7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
      13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
      10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
      3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14 },
    { 2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
      14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
      4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
      11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3 },
    { 12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
      10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
      9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
      4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13 },
    { 4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
      13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
      1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
      6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12 },
    { 13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
      1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
      7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
      2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11 },
}

---@param src integer[]
---@param map integer[]
---@return integer[]
local function permute(src, map)
    local out = {}
    for i = 1, #map do out[i] = src[map[i]] end
    return out
end

---@param str string
---@param from integer
---@return integer[] 64 位，高位在前
local function bits(str, from)
    local out = {}
    for i = 0, 7 do
        local byte = str:byte(from + i)
        for b = 7, 0, -1 do out[#out + 1] = bit.band(bit.rshift(byte, b), 1) end
    end
    return out
end

---@param src integer[]
---@return string
local function bytes(src)
    local out = {}
    for i = 0, 7 do
        local v = 0
        for b = 1, 8 do v = v * 2 + src[i * 8 + b] end
        out[#out + 1] = string.char(v)
    end
    return table.concat(out)
end

---@param key string 8 字节
---@return integer[][] 16 个 48 位子密钥
local function schedule(key)
    local kp = permute(bits(key, 1), PC1)
    local c, d = {}, {}
    for i = 1, 28 do c[i], d[i] = kp[i], kp[i + 28] end
    local keys = {}
    for round = 1, 16 do
        for _ = 1, SHIFTS[round] do
            table.insert(c, table.remove(c, 1))
            table.insert(d, table.remove(d, 1))
        end
        local cd = {}
        for i = 1, 28 do cd[i], cd[i + 28] = c[i], d[i] end
        keys[round] = permute(cd, PC2)
    end
    return keys
end

---@param block integer[] 64 位
---@param keys integer[][]
---@param decrypt boolean
---@return integer[]
local function crypt(block, keys, decrypt)
    local ip = permute(block, IP)
    local l, r = {}, {}
    for i = 1, 32 do l[i], r[i] = ip[i], ip[i + 32] end
    for round = 1, 16 do
        local k = keys[decrypt and 17 - round or round]
        local er = permute(r, E)
        local f = {}
        for box = 0, 7 do
            local base = box * 6
            local x = {}
            for i = 1, 6 do x[i] = bit.bxor(er[base + i], k[base + i]) end
            local row = x[1] * 2 + x[6]
            local col = x[2] * 8 + x[3] * 4 + x[4] * 2 + x[5]
            local v = SBOX[box + 1][row * 16 + col + 1]
            for i = 1, 4 do f[box * 4 + i] = bit.band(bit.rshift(v, 4 - i), 1) end
        end
        f = permute(f, P)
        local nr = {}
        for i = 1, 32 do nr[i] = bit.bxor(l[i], f[i]) end
        l, r = r, nr
    end
    local pre = {}
    for i = 1, 32 do pre[i], pre[i + 32] = r[i], l[i] end
    return permute(pre, FP)
end

---@param a string
---@param b string
---@return string
local function xor8(a, b)
    local out = {}
    for i = 1, 8 do out[i] = string.char(bit.bxor(a:byte(i), b:byte(i))) end
    return table.concat(out)
end

--- DES-CBC 加密，PKCS7 补位。
---@param plain string
---@param key string 8 字节
---@param iv string 8 字节
---@return string 原始字节
function Des.encrypt(plain, key, iv)
    local keys = schedule(key)
    local pad = 8 - #plain % 8
    plain = plain .. string.rep(string.char(pad), pad)
    local out, prev = {}, iv
    for i = 1, #plain, 8 do
        prev = bytes(crypt(bits(xor8(plain:sub(i, i + 7), prev), 1), keys, false))
        out[#out + 1] = prev
    end
    return table.concat(out)
end

--- DES-CBC 解密并去 PKCS7 补位；补位不合法返回 nil。
---@param cipher string
---@param key string
---@param iv string
---@return string|nil
function Des.decrypt(cipher, key, iv)
    if #cipher == 0 or #cipher % 8 ~= 0 then return nil end
    local keys = schedule(key)
    local out, prev = {}, iv
    for i = 1, #cipher, 8 do
        local block = cipher:sub(i, i + 7)
        out[#out + 1] = xor8(bytes(crypt(bits(block, 1), keys, true)), prev)
        prev = block
    end
    local plain = table.concat(out)
    local pad = plain:byte(-1)
    if pad < 1 or pad > 8 or plain:sub(-pad) ~= string.rep(string.char(pad), pad) then return nil end
    return plain:sub(1, -pad - 1)
end

---@param plain string
---@param key string
---@param iv string
---@return string
function Des.encryptBase64(plain, key, iv)
    return (require("mime").b64(Des.encrypt(plain, key, iv)))
end

---@param text string
---@param key string
---@param iv string
---@return string|nil
function Des.decryptBase64(text, key, iv)
    local raw = require("mime").unb64(text)
    return raw and Des.decrypt(raw, key, iv)
end

return Des
