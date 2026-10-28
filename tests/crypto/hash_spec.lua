--[[--
SM3 已知答案；hex 互转；HKDF-SHA256（RFC 5869 用例 1，取前 32 字节）。

MD5 / SHA-1 / SHA-256 来自 KOReader `ffi/sha2`，本仓库不再自带实现。

@module tests.crypto.hash_spec
--]]

local Assert = require("support.assert")

local Hex = require("crypto.hex")
local Sm3 = require("crypto.sm3")
local Gcm = require("crypto.gcm")

Assert.eq(Sm3.hex(""), "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b")
Assert.eq(Sm3.hex("abc"), "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0")

Assert.eq(Hex.to_hex("\0\1\254\255"), "0001feff")
Assert.eq(Hex.from_hex("0001FEff"), "\0\1\254\255")
Assert.eq(Hex.from_hex("00 01\n fe ff"), "\0\1\254\255", "whitespace is ignored")
Assert.eq(Hex.from_hex(""), "")

local ikm = string.rep("\11", 22)
local salt = Hex.from_hex("000102030405060708090a0b0c")
local info = Hex.from_hex("f0f1f2f3f4f5f6f7f8f9")
Assert.eq(Hex.to_hex(Gcm.hkdf(ikm, salt, info, 32)),
    "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf")
Assert.eq(#Gcm.hkdf(ikm, salt, info, 16), 16)
Assert.errors(function() Gcm.hkdf(ikm, salt, info, 33) end, "one block only")

-- 旧 crypto.md5 / sha1 / sha256 已删，不得再被 require 到
for _idx, name in ipairs({ "crypto.md5", "crypto.sha1", "crypto.sha256" }) do
    Assert.is_nil(package.searchpath(name, package.path), name .. " removed")
end
