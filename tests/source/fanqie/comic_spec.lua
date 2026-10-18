--[[--
番茄漫画章节：JSON 页清单 → <img>，页图 AES-GCM 解密（只解 CTR 流）。

@module tests.source.fanqie.comic_spec
--]]

local Assert = require("support.assert")
package.preload["json"] = function()
    local J = require("support.json_stub")
    return { encode = J.encode, decode = J.decode }
end
package.loaded["json"] = nil

local Aes = require("crypto.aes")
local Comic = require("source.fanqie.comic")

local key_hex = string.rep("00", 32)
local html, key = Comic.parse('{"picInfos":[{"picUrl":"https://x/a.jpg?a=1&b=2"},{"picUrl":"https://x/b.jpg"}],'
    .. '"encrypt":true,"encrypt_key":"' .. key_hex .. '"}')
Assert.matches(html, 'src="https://x/a.jpg%?a=1&amp;b=2"')
Assert.matches(html, 'src="https://x/b.jpg"')
Assert.eq(key, string.rep("\0", 32))

local _, plain_key = Comic.parse('{"picInfos":[{"picUrl":"https://x/a.jpg"}]}')
Assert.is_nil(plain_key)

Assert.is_nil(Comic.parse("<p>正文</p>"))
Assert.is_nil(Comic.parse('{"picInfos":[]}'))

-- NIST GCM 测试向量 2：全零 128 位密钥与 IV，明文 16 个零字节
local iv = string.rep("\0", 12)
local sealed = iv .. Aes.from_hex("0388dace60b6a392f328c2b971b2fe78" .. "ab6e47d42cec13bdf53a67b21257bddf")
Assert.eq(Comic.decrypt(sealed, string.rep("\0", 16)), string.rep("\0", 16))
Assert.eq(Comic.decrypt("raw", nil), "raw")
Assert.is_nil(Comic.decrypt("short", string.rep("\0", 16)))
