--[[--
二进制与十六进制互转。

@module koplugin.book.crypto.hex
--]]

local Hex = {}

---@param bin string
---@return string 小写十六进制
function Hex.to_hex(bin)
    return (bin:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

---@param hex string 忽略空白；奇数长度时末位原样留下（与旧 Aes.from_hex 一致）
---@return string
function Hex.from_hex(hex)
    return (hex:gsub("%s+", ""):gsub("..", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

return Hex
