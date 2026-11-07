--[[--
电脑阅读器的 Base64、XOR、AES 及组合顺序，失败不能缓存密文。

@module tests.source.netease.content_spec
--]]

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Text = require("utils.text")
local Aes = require("crypto.aes")
local Mapper = require("source.netease.mapper")
local key = "1234567890abcdef"
local plain = "<p>甲乙</p>"
local function decode(body, steps)
    return Mapper.content({
        content = Text.base64Encode(body),
        x = steps and Text.base64Encode(JSON.encode(steps)),
    })
end
Assert.eq(decode(plain), plain)
local ascii = "<p>hello</p>"
local encrypted = ascii:gsub(".", function(ch) return string.char(require("bit").bxor(ch:byte(), 7)) end)
Assert.eq(decode(encrypted, { { m = 1, k = "7" } }), ascii)
Assert.eq(decode("<p>电乙</p>", { { m = 1, k = "0" } }), "<p>电乙</p>")
Assert.eq(decode(Aes.to_hex(Aes.ecb_encrypt(plain, key)), { { m = 2, k = key } }), plain)
local hex = Aes.to_hex(Aes.ecb_encrypt(plain, key))
local hidden = hex:gsub(".", function(ch) return string.char(require("bit").bxor(ch:byte(), 7)) end)
Assert.eq(decode(hidden, { { m = 1, k = "7" }, { m = 2, k = key } }), plain)
Assert.eq(decode(Aes.to_hex(Aes.ecb_encrypt(encrypted, key)),
    { { m = 2, k = key }, { m = 1, k = "7" } }), ascii)
for _idx, steps in ipairs({ { { m = 3, k = key } }, { { m = 2, k = "short" } }, { false }, {} }) do
    local html, err = decode(hex, steps)
    Assert.is_nil(html)
    Assert.eq(err, "正文解析失败")
end
local html, err = Mapper.content({ content = "eA==", x = "eA==" })
Assert.is_nil(html)
Assert.eq(err, "正文解析失败")
