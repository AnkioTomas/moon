--[[--
AES-128/192/256（ECB/CBC）+ PKCS7。纯 LuaJIT。
密钥 16/24/32 字节。ECB 加密默认填充；`pad == false` 表示数据已对齐。

crypto 没有 init.lua，按文件名 require（crypto.aes / crypto.sm2 …）；全是无状态模块函数。
密钥、密文、摘要都是原始字节，十六进制用 crypto.hex 转；不解析 PEM / ASN.1。
Aes.pkcs7_pad / pkcs7_unpad / from_hex / to_hex 就是 crypto.pad / crypto.hex 的同一批函数（旧调用不用改）。
去填充只看末字节给出的长度，不逐字节核对填充内容。SM4 同名函数在 crypto.sm4 上，密钥 16 字节。

@module koplugin.book.crypto.aes
--]]

local bit = require("bit")
local band, bxor = bit.band, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift

local Hex = require("crypto.hex")
local Pad = require("crypto.pad")

local Aes = {}

Aes.pkcs7_pad = Pad.pkcs7_pad
Aes.pkcs7_unpad = Pad.pkcs7_unpad
Aes.from_hex = Hex.from_hex
Aes.to_hex = Hex.to_hex

local SBOX = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
}

local INV_SBOX = {}
for i = 0, 255 do INV_SBOX[SBOX[i + 1]] = i end

local RCON = { 0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36 }

local function xtime(a)
    a = band(a, 0xff)
    local r = lshift(a, 1)
    if band(a, 0x80) ~= 0 then r = bxor(r, 0x1b) end
    return band(r, 0xff)
end

local function mul(a, b)
    local r = 0
    a, b = band(a, 0xff), band(b, 0xff)
    for _bit = 1, 8 do
        if band(b, 1) ~= 0 then r = bxor(r, a) end
        a = xtime(a)
        b = rshift(b, 1)
    end
    return band(r, 0xff)
end

local function sub_bytes(s)
    for i = 1, 16 do s[i] = SBOX[s[i] + 1] end
end

local function inv_sub_bytes(s)
    for i = 1, 16 do s[i] = INV_SBOX[s[i]] end
end

local function shift_rows(s)
    local t = s[2]; s[2] = s[6]; s[6] = s[10]; s[10] = s[14]; s[14] = t
    t = s[3]; s[3] = s[11]; s[11] = t; t = s[7]; s[7] = s[15]; s[15] = t
    t = s[4]; s[4] = s[16]; s[16] = s[12]; s[12] = s[8]; s[8] = t
end

local function inv_shift_rows(s)
    local t = s[14]; s[14] = s[10]; s[10] = s[6]; s[6] = s[2]; s[2] = t
    t = s[3]; s[3] = s[11]; s[11] = t; t = s[7]; s[7] = s[15]; s[15] = t
    t = s[4]; s[4] = s[8]; s[8] = s[12]; s[12] = s[16]; s[16] = t
end

local function mix_columns(s)
    for c = 0, 3 do
        local i = c * 4 + 1
        local a, b, d, e = s[i], s[i + 1], s[i + 2], s[i + 3]
        s[i]     = bxor(mul(a, 2), mul(b, 3), d, e)
        s[i + 1] = bxor(a, mul(b, 2), mul(d, 3), e)
        s[i + 2] = bxor(a, b, mul(d, 2), mul(e, 3))
        s[i + 3] = bxor(mul(a, 3), b, d, mul(e, 2))
    end
end

local function inv_mix_columns(s)
    for c = 0, 3 do
        local i = c * 4 + 1
        local a, b, d, e = s[i], s[i + 1], s[i + 2], s[i + 3]
        s[i]     = bxor(mul(a, 0x0e), mul(b, 0x0b), mul(d, 0x0d), mul(e, 0x09))
        s[i + 1] = bxor(mul(a, 0x09), mul(b, 0x0e), mul(d, 0x0b), mul(e, 0x0d))
        s[i + 2] = bxor(mul(a, 0x0d), mul(b, 0x09), mul(d, 0x0e), mul(e, 0x0b))
        s[i + 3] = bxor(mul(a, 0x0b), mul(b, 0x0d), mul(d, 0x09), mul(e, 0x0e))
    end
end

local function add_round_key(s, rk, round)
    local o = round * 16
    for i = 1, 16 do s[i] = bxor(s[i], rk[o + i]) end
end

local function expand_key(key)
    local nk = #key / 4
    if nk ~= 4 and nk ~= 6 and nk ~= 8 then error("aes: bad key length") end
    local nr = nk + 6
    local nwords = 4 * (nr + 1)
    local w = {}
    for i = 1, #key do w[i] = key:byte(i) end
    for i = nk, nwords - 1 do
        local t0 = w[(i - 1) * 4 + 1]
        local t1 = w[(i - 1) * 4 + 2]
        local t2 = w[(i - 1) * 4 + 3]
        local t3 = w[(i - 1) * 4 + 4]
        if i % nk == 0 then
            local a = bxor(SBOX[t1 + 1], RCON[math.floor(i / nk)])
            local b = SBOX[t2 + 1]
            local c = SBOX[t3 + 1]
            local d = SBOX[t0 + 1]
            t0, t1, t2, t3 = a, b, c, d
        elseif nk > 6 and i % nk == 4 then
            t0, t1, t2, t3 = SBOX[t0 + 1], SBOX[t1 + 1], SBOX[t2 + 1], SBOX[t3 + 1]
        end
        local prev = i - nk
        w[i * 4 + 1] = bxor(w[prev * 4 + 1], t0)
        w[i * 4 + 2] = bxor(w[prev * 4 + 2], t1)
        w[i * 4 + 3] = bxor(w[prev * 4 + 3], t2)
        w[i * 4 + 4] = bxor(w[prev * 4 + 4], t3)
    end
    return w, nr
end

local function block_to_state(block)
    local s = {}
    for i = 1, 16 do s[i] = block:byte(i) end
    return s
end

local function state_to_block(s)
    local t = {}
    for i = 1, 16 do t[i] = string.char(s[i]) end
    return table.concat(t)
end

local function encrypt_block(block, rk, nr)
    local s = block_to_state(block)
    add_round_key(s, rk, 0)
    for round = 1, nr - 1 do
        sub_bytes(s); shift_rows(s); mix_columns(s); add_round_key(s, rk, round)
    end
    sub_bytes(s); shift_rows(s); add_round_key(s, rk, nr)
    return state_to_block(s)
end

local function decrypt_block(block, rk, nr)
    local s = block_to_state(block)
    add_round_key(s, rk, nr)
    for round = nr - 1, 1, -1 do
        inv_shift_rows(s); inv_sub_bytes(s); add_round_key(s, rk, round); inv_mix_columns(s)
    end
    inv_shift_rows(s); inv_sub_bytes(s); add_round_key(s, rk, 0)
    return state_to_block(s)
end

local function xor_block(a, b)
    local t = {}
    for i = 1, 16 do
        t[i] = string.char(bxor(a:byte(i), b:byte(i)))
    end
    return table.concat(t)
end

---@param data string
---@param key string 16/24/32 字节
---@param pad boolean|nil 默认 PKCS#7；false 要求长度已对齐
---@return string
function Aes.ecb_encrypt(data, key, pad)
    local rk, nr = expand_key(key)
    local buf = pad == false and data or Aes.pkcs7_pad(data, 16)
    if #buf % 16 ~= 0 then error("aes: bad length") end
    local out = {}
    for i = 1, #buf, 16 do
        out[#out + 1] = encrypt_block(buf:sub(i, i + 15), rk, nr)
    end
    return table.concat(out)
end

---@param data string
---@param key string 16/24/32 字节
---@param pad boolean|nil 默认去掉 PKCS#7
---@return string
function Aes.ecb_decrypt(data, key, pad)
    if #data % 16 ~= 0 then error("aes: bad length") end
    local rk, nr = expand_key(key)
    local out = {}
    for i = 1, #data, 16 do
        out[#out + 1] = decrypt_block(data:sub(i, i + 15), rk, nr)
    end
    local raw = table.concat(out)
    if pad == false then return raw end
    return Aes.pkcs7_unpad(raw, 16)
end

---@param data string
---@param key string
---@param iv string 16 字节
---@param pad boolean|nil 默认 PKCS#7
---@return string
function Aes.cbc_encrypt(data, key, iv, pad)
    if #iv ~= 16 then error("aes: bad iv") end
    local rk, nr = expand_key(key)
    local buf = pad == false and data or Aes.pkcs7_pad(data, 16)
    if #buf % 16 ~= 0 then error("aes: bad length") end
    local prev = iv
    local out = {}
    for i = 1, #buf, 16 do
        local enc = encrypt_block(xor_block(buf:sub(i, i + 15), prev), rk, nr)
        out[#out + 1] = enc
        prev = enc
    end
    return table.concat(out)
end

---@param data string
---@param key string
---@param iv string
---@param pad boolean|nil 默认去掉 PKCS#7
---@return string
function Aes.cbc_decrypt(data, key, iv, pad)
    if #iv ~= 16 or #data % 16 ~= 0 then error("aes: bad length") end
    local rk, nr = expand_key(key)
    local prev = iv
    local out = {}
    for i = 1, #data, 16 do
        local block = data:sub(i, i + 15)
        out[#out + 1] = xor_block(decrypt_block(block, rk, nr), prev)
        prev = block
    end
    local raw = table.concat(out)
    if pad == false then return raw end
    return Aes.pkcs7_unpad(raw, 16)
end

return Aes
