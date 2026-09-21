--[[--
AES-128（ECB/CBC）+ PKCS7。纯 LuaJIT，移植自 fanqie-re。

@module koplugin.book.source.fanqie.reading.aes
--]]

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, ror = bit.lshift, bit.rshift, bit.ror

local Aes = {}

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
    for _ = 1, 8 do
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
    assert(#key == 16)
    local w = {}
    for i = 1, 16 do w[i] = key:byte(i) end
    for i = 4, 43 do
        local t0 = w[(i - 1) * 4 + 1]
        local t1 = w[(i - 1) * 4 + 2]
        local t2 = w[(i - 1) * 4 + 3]
        local t3 = w[(i - 1) * 4 + 4]
        if i % 4 == 0 then
            local a = SBOX[t1 + 1]
            local b = SBOX[t2 + 1]
            local c = SBOX[t3 + 1]
            local d = SBOX[t0 + 1]
            a = bxor(a, RCON[i / 4])
            t0, t1, t2, t3 = a, b, c, d
        end
        w[i * 4 + 1] = bxor(w[(i - 4) * 4 + 1], t0)
        w[i * 4 + 2] = bxor(w[(i - 4) * 4 + 2], t1)
        w[i * 4 + 3] = bxor(w[(i - 4) * 4 + 3], t2)
        w[i * 4 + 4] = bxor(w[(i - 4) * 4 + 4], t3)
    end
    -- w indexed from 0*4+1 for round 0 → 43*4+4; flatten to 176 bytes 1-based
    local rk = {}
    for i = 0, 43 do
        for j = 1, 4 do
            rk[i * 4 + j] = w[i * 4 + j]
        end
    end
    return rk
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

local function encrypt_block(block, rk)
    local s = block_to_state(block)
    add_round_key(s, rk, 0)
    for round = 1, 9 do
        sub_bytes(s); shift_rows(s); mix_columns(s); add_round_key(s, rk, round)
    end
    sub_bytes(s); shift_rows(s); add_round_key(s, rk, 10)
    return state_to_block(s)
end

local function decrypt_block(block, rk)
    local s = block_to_state(block)
    add_round_key(s, rk, 10)
    for round = 9, 1, -1 do
        inv_shift_rows(s); inv_sub_bytes(s); add_round_key(s, rk, round); inv_mix_columns(s)
    end
    inv_shift_rows(s); inv_sub_bytes(s); add_round_key(s, rk, 0)
    return state_to_block(s)
end

function Aes.pkcs7_pad(data, block)
    block = block or 16
    local n = block - (#data % block)
    return data .. string.rep(string.char(n), n)
end

function Aes.pkcs7_unpad(data, block)
    block = block or 16
    if #data == 0 or (#data % block) ~= 0 then
        error("bad pkcs7 length")
    end
    local n = data:byte(#data)
    if n < 1 or n > block then error("bad pkcs7 padding") end
    return data:sub(1, #data - n)
end

---@param data string
---@param key string 16 bytes
---@return string
function Aes.ecb_encrypt(data, key)
    local rk = expand_key(key)
    local padded = Aes.pkcs7_pad(data, 16)
    local out = {}
    for i = 1, #padded, 16 do
        out[#out + 1] = encrypt_block(padded:sub(i, i + 15), rk)
    end
    return table.concat(out)
end

---@param data string already multiple of 16, no padding expected if nopad
---@param key string
---@param iv string 16 bytes
---@param pad boolean|nil default true
---@return string
function Aes.cbc_encrypt(data, key, iv, pad)
    assert(#key == 16 and #iv == 16)
    local rk = expand_key(key)
    local buf = pad == false and data or Aes.pkcs7_pad(data, 16)
    assert(#buf % 16 == 0)
    local prev = iv
    local out = {}
    for i = 1, #buf, 16 do
        local block = buf:sub(i, i + 15)
        local xored = {}
        for j = 1, 16 do
            xored[j] = string.char(bxor(block:byte(j), prev:byte(j)))
        end
        local enc = encrypt_block(table.concat(xored), rk)
        out[#out + 1] = enc
        prev = enc
    end
    return table.concat(out)
end

---@param data string
---@param key string
---@param iv string
---@param pad boolean|nil default true (strip pkcs7)
---@return string
function Aes.cbc_decrypt(data, key, iv, pad)
    assert(#key == 16 and #iv == 16 and #data % 16 == 0)
    local rk = expand_key(key)
    local prev = iv
    local out = {}
    for i = 1, #data, 16 do
        local block = data:sub(i, i + 15)
        local dec = decrypt_block(block, rk)
        local plain = {}
        for j = 1, 16 do
            plain[j] = string.char(bxor(dec:byte(j), prev:byte(j)))
        end
        out[#out + 1] = table.concat(plain)
        prev = block
    end
    local raw = table.concat(out)
    if pad == false then return raw end
    return Aes.pkcs7_unpad(raw, 16)
end

---@param hex string
---@return string
function Aes.from_hex(hex)
    return (hex:gsub("%s+", ""):gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

---@param bin string
---@return string
function Aes.to_hex(bin)
    return (bin:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

return Aes
