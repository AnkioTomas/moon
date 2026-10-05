--[[--
PKCS#7 填充。块长由调用方给出（AES / SM4 都是 16）。

@module koplugin.book.crypto.pad
--]]

local Pad = {}

---@param data string
---@param block integer|nil 默认 16
---@return string
function Pad.pkcs7_pad(data, block)
    block = block or 16
    local n = block - (#data % block)
    return data .. string.rep(string.char(n), n)
end

---@param data string
---@param block integer|nil 默认 16
---@return string
function Pad.pkcs7_unpad(data, block)
    block = block or 16
    if #data == 0 or (#data % block) ~= 0 then
        error("bad pkcs7 length")
    end
    local n = data:byte(#data)
    if n < 1 or n > block then error("bad pkcs7 padding") end
    return data:sub(1, #data - n)
end

return Pad
