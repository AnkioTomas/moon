--[[--
SM2 公钥、签名、加密的已知答案。签名与 gmssl 对照过；密文按 GM/T 0003.4 的 C1||C3||C2。

@module tests.crypto.sm2_spec
--]]

local Assert = require("support.assert")
local Hex = require("crypto.hex")
local Sm2 = require("crypto.sm2")

local d = Hex.from_hex("128B2FA8BD433C6C068C8D803DFF79792A519A55171B1B650C23661D15897263")
local pub = Sm2.public_key(d)
Assert.eq(Hex.to_hex(pub),
    "04d5548c7825cbb56150a3506cd57464af8a1ae0519dfaf3c58221dc810caf28dd"
        .. "921073768fe3d59ce54e79a49445cf73fed23086537027264d168946d479533e")

local k = Hex.from_hex("6CB28D99385C175C94F94E934817663FC176D925DD72B727260DBAAE1FB2F96F")
local msg = "message digest"
local sig = Sm2.sign(msg, d, nil, k)
Assert.eq(Hex.to_hex(sig),
    "611c15a886a1ae2b0a631f3db47b329e75e2daa1e83826252352e9efb7682f85"
        .. "e74d5fde03f646f642647cd4bdd01520702842df50708a6afe7d2868c9554a41")
Assert.is_true(Sm2.verify(msg, sig, pub))
Assert.is_true(Sm2.verify(msg, sig, pub:sub(2)))
Assert.is_false(Sm2.verify("message digesu", sig, pub))

local ek = Hex.from_hex("4C62EEFD6ECFC2B95B92FD6C3D9575148AFA17425546D49018E5388D49DD7B4F")
local plain = "encryption standard"
local ct = Sm2.encrypt(plain, pub, ek)
Assert.eq(Hex.to_hex(ct),
    "0411c88ae04cec1ba554d03d5b5970333a83585826c2a985de5520d9e934389e"
        .. "fb84b52d344fb21aa8ea38a4940c8332692b8d4da2393549212eafdc0f11ca5c9c"
        .. "ea113b55ec32dcd5be2a0ee96101e0f10b2f859877d2d4dcbe7662206bb527ab"
        .. "c71cb5890117ad7c107c65b647cf8b305bbe55")
Assert.eq(Sm2.decrypt(ct, d), plain)
Assert.eq(Sm2.decrypt(Sm2.encrypt("", pub, ek), d), "")

local bad = ct:sub(1, 70) .. string.char((ct:byte(71) + 1) % 256) .. ct:sub(72)
Assert.errors(function() Sm2.decrypt(bad, d) end, "bad ciphertext")
