--[[--
MD5 / SHA-1 / SHA-256 / SM3 已知答案。

@module tests.crypto.hash_spec
--]]

local Assert = require("support.assert")

local Md5 = require("crypto.md5")
local Sha1 = require("crypto.sha1")
local Sha256 = require("crypto.sha256")
local Sm3 = require("crypto.sm3")

Assert.eq(Md5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
Assert.eq(Md5.hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
Assert.eq(Md5.hex(string.rep("a", 100)), "36a92cc94a9e0fa21f625f8bfb007adf")
Assert.eq(#Md5.hash("abc"), 16)

Assert.eq(Sha1.hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
Assert.eq(Sha1.hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
Assert.eq(Sha1.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "84983e441c3bd26ebaae4aa1f95129e5e54670f1")

Assert.eq(Sha256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
Assert.eq(Sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
Assert.eq(Sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
Assert.eq(Sha256.hex(string.rep("a", 1000)),
    "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")

Assert.eq(Sm3.hex(""), "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b")
Assert.eq(Sm3.hex("abc"), "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0")
