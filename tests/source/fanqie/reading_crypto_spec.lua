--[[--
番茄 reading crypto 向量（离线）。

@module tests.source.fanqie.reading_crypto_spec
--]]

local Assert = require("support.assert")

package.loaded["source.fanqie.reading.crypto"] = nil
package.loaded["source.fanqie.reading.aes"] = nil

local Aes = require("source.fanqie.reading.aes")
local Crypto = require("source.fanqie.reading.crypto")

local key = Aes.from_hex(Crypto.HARDCODED_KEY_HEX)
local iv = "1234567890123456"
local pt = Aes.from_hex("2b5dbca76c4902000000000000000000")
local ct = Aes.cbc_encrypt(pt, key, iv, true)
Assert.eq(Aes.to_hex(ct), "64fd9775e48333728345235490bca65492c8c2ccd7832564732fb54839593fe2")

local content = Crypto.build_register_content(643680972856619, 0, "1234567890123456")
Assert.eq(content, "MTIzNDU2Nzg5MDEyMzQ1NmT9l3XkgzNyg0UjVJC8plSSyMLM14MlZHMvtUg5WT/i")

-- decrypt_server_key roundtrip
local session = Aes.from_hex("00112233445566778899aabbccddeeff")
local iv2 = "0123456789abcdef"
local blob = require("utils.text").base64Encode(iv2 .. Aes.cbc_encrypt(session, key, iv2, true))
Assert.eq(Crypto.decrypt_server_key(blob), "00112233445566778899AABBCCDDEEFF")

local q = Crypto.build_batch_full_query({
    install_id = "1", device_id = "2", version_code = "73733", version_name = "7.3.7.33",
}, "7342475219212192830", { "7463695105224884760" }, 1000)
local qs = Crypto.encode_query(q)
Assert.matches(qs, "item_ids=7463695105224884760")
Assert.is_true(not qs:find("%%2C", 1, true))
Assert.matches(qs, "book_id=7342475219212192830")
