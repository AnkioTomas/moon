--[[--
RSA PKCS#1 v1.5。签名和一段密文来自 OpenSSL 的 512 位密钥。

@module tests.crypto.rsa_spec
--]]

local Assert = require("support.assert")
local Hex = require("crypto.hex")
local Rsa = require("crypto.rsa")

local n = Hex.from_hex(
    "eb4eadd7f6dc367db54146383ee01829d42c8db33111c82e3158919334"
        .. "475149764a7f54dad1e7c44851bc20c7bf5dfb0f0931dde7c1434724806122183b57e5")
local d = Hex.from_hex(
    "89731a254ef3ef789aca18447ea5d4378ad2c3aaea7ce29be9033d75e9"
        .. "51c76ead3d98993ce268c306e5a04250bb784eb39c784ccb5b91131f14727231741581")
local sig = Hex.from_hex(
    "db6ac24c1438e7400d6f9f2fe1d742edbdbc55a5be126608a5797edbc5"
        .. "280a1ad52e41afcded4ee0252a9fb1562a1bc9bee3a9140f6c7a3c869fa52a30e1de53")
local ct = Hex.from_hex(
    "a85b4f21d126279da7c46e77b45220ce62bee0307ab0deaea25c2763e5"
        .. "390db5d350bd41a9549cf3830eb4ac446d3ab5b525640510325f7e8169d111affff2c2")

Assert.eq(#n, 64)
Assert.eq(Rsa.sign("hi", n, d), sig)
Assert.eq(Rsa.sign("hi", n, d, "md5"), Hex.from_hex(
    "d4b6e5ed99438b2fce811c7d90e7a9793d80895a81b122c173c0817aa0f4"
        .. "10697e8229ab919ab7a419aa5f412c29e72cc7e1d9a144502c6ac696dbefe24e4307"))
Assert.eq(Rsa.sign("hi", n, d, "sha1"), Hex.from_hex(
    "ba5f743292fc463e235bfddda4faf20e5e5ac4f38dac532ff9d9e43b8dee"
        .. "f9485c74303a2ed461467f3d47cb9337cc943558c4dbd9d2eef35476f0deca08602f"))
Assert.is_true(Rsa.verify("hi", sig, n))
Assert.is_false(Rsa.verify("hj", sig, n))
Assert.eq(Rsa.decrypt(ct, n, d), "hi")

local fixed = Rsa.encrypt("hi", n, nil, function(k)
    return string.rep("\255", k)
end)
Assert.eq(Rsa.decrypt(fixed, n, d), "hi")
Assert.eq(#fixed, #n)

Assert.errors(function()
    Rsa.encrypt(string.rep("a", #n), n, nil, function(k)
        return string.rep("\1", k)
    end)
end, "too long")
Assert.errors(function() Rsa.keypair(520) end, "bad bits")

local kn, ke, kd = Rsa.keypair(512)
Assert.eq(#kn, 64)
Assert.eq(#kd, 64)
Assert.eq(Rsa.decrypt(Rsa.encrypt("ping", kn, ke), kn, kd), "ping")
Assert.is_true(Rsa.verify("ping", Rsa.sign("ping", kn, kd, "sha1"), kn, ke, "sha1"))
