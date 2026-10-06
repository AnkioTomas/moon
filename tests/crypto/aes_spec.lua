--[[--
AES-128/192/256 ECB/CBC 已知答案，以及 PKCS#7 往返。

@module tests.crypto.aes_spec
--]]

local Assert = require("support.assert")
local Aes = require("crypto.aes")

local function h(hex)
    return Aes.from_hex(hex)
end

local block = h("00112233445566778899aabbccddeeff")

Assert.eq(Aes.to_hex(Aes.ecb_encrypt(block, h("000102030405060708090a0b0c0d0e0f"), false)),
    "69c4e0d86a7b0430d8cdb78070b4c55a")
Assert.eq(Aes.to_hex(Aes.ecb_encrypt(block, h("000102030405060708090a0b0c0d0e0f1011121314151617"), false)),
    "dda97ca4864cdfe06eaf70a0ec0d7191")
Assert.eq(Aes.to_hex(Aes.ecb_encrypt(block,
    h("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"), false)),
    "8ea2b7ca516745bfeafc49904b496089")

local iv = h("000102030405060708090a0b0c0d0e0f")
local key = h("000102030405060708090a0b0c0d0e0f")
Assert.eq(Aes.to_hex(Aes.cbc_encrypt(block, key, iv, false)), "76d0627da1d290436e21a4af7fca94b7")
Assert.eq(Aes.cbc_decrypt(Aes.cbc_encrypt(block, key, iv, false), key, iv, false), block)

Assert.eq(Aes.to_hex(Aes.ecb_encrypt("hi", key)), "b758f283427e7c0ec8ebdc457ec3609e")
Assert.eq(Aes.ecb_decrypt(Aes.ecb_encrypt("hi", key), key), "hi")
Assert.eq(Aes.cbc_decrypt(Aes.cbc_encrypt("", key, iv), key, iv), "")

local long = "hello world this is longer than one block!!"
Assert.eq(Aes.cbc_decrypt(Aes.cbc_encrypt(long, key, iv), key, iv), long)

Assert.eq(Aes.pkcs7_pad(""), string.rep(string.char(16), 16))
Assert.eq(Aes.pkcs7_unpad(Aes.pkcs7_pad("x")), "x")
Assert.errors(function() Aes.ecb_encrypt("abc", "short") end, "bad key")
