--[[--
二进制与十六进制互转：KOReader `ffi/sha2` 的 bin_to_hex / hex_to_bin，from_hex 额外忽略空白。

@module koplugin.book.crypto.hex
--]]

local sha2 = require("ffi/sha2")

local Hex = {}

--- 小写十六进制
Hex.to_hex = sha2.bin_to_hex

---@param hex string 忽略空白
---@return string
function Hex.from_hex(hex)
    return sha2.hex_to_bin((hex:gsub("%s+", "")))
end

return Hex
