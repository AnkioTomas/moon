--[[--
番茄 reading 签名向量（离线）。

@module tests.source.fanqie.reading_sign_spec
--]]

local Assert = require("support.assert")

package.loaded["source.fanqie.reading.sign"] = nil
package.loaded["source.fanqie.reading.aes"] = nil
package.loaded["source.fanqie.reading.sm3"] = nil

local Aes = require("source.fanqie.reading.aes")
local Sm3 = require("source.fanqie.reading.sm3")
local Sign = require("source.fanqie.reading.sign")

Assert.eq(Sm3.hex(""), "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b")
Assert.eq(Sm3.hex("abc"), "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0")
Assert.eq(Aes.to_hex(Sign.derive_inner_key()):sub(1, 32), "fc78e0a9657a0c748ce51559903ccf03")

local ladon = Sign.encrypt_ladon(1789957197, Aes.from_hex("1b98ce68"))
Assert.eq(ladon, "G5jOaLRVvJuv4+NwKK5O28l5Otk8CtR/oS5UUASQ16HNqKIl")

local helios = Sign.encrypt_helios(1789957197, Aes.from_hex("9af455f3"))
Assert.eq(helios, "mvRV81hWfK8mji4oDqkBUaKNIcydz7kADrxZKHO7vEnxeFQ/")

local argus = Sign.encrypt_argus(
    "aid=1967&device_id=1", 1789949275, "3405654380789289", { rand_val = 1 })
local raw = require("utils.text").base64Decode(argus)
Assert.eq(raw:sub(1, 2), string.char(0xf2, 0x81))
Assert.eq(#raw, 194)
