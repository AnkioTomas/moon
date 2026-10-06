--[[--
SM4 ECB/CBC 已知答案。

@module tests.crypto.sm4_spec
--]]

local Assert = require("support.assert")
local Hex = require("crypto.hex")
local Sm4 = require("crypto.sm4")

local key = Hex.from_hex("0123456789abcdeffedcba9876543210")
local block = Hex.from_hex("0123456789abcdeffedcba9876543210")
local iv = Hex.from_hex("000102030405060708090a0b0c0d0e0f")

Assert.eq(Hex.to_hex(Sm4.ecb_encrypt(block, key, false)), "681edf34d206965e86b3e94f536e4246")
Assert.eq(Sm4.ecb_decrypt(Sm4.ecb_encrypt(block, key, false), key, false), block)

Assert.eq(Hex.to_hex(Sm4.cbc_encrypt(block .. block, key, iv, false)),
    "a9a268883a336315bac0c9c9ff350ab1b236a4a85616d4aabf0a83555c7d4115")
Assert.eq(Hex.to_hex(Sm4.cbc_encrypt("hi", key, iv)), "58d461024512f6f48126786fe58aced5")
Assert.eq(Sm4.cbc_decrypt(Sm4.cbc_encrypt("hi", key, iv), key, iv), "hi")
Assert.eq(Sm4.ecb_decrypt(Sm4.ecb_encrypt("", key), key), "")
