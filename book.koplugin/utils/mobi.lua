--[[--
MOBI 族（mobi / azw / azw3）文件头的最小读取：只看 DRM 加密标记。纯 Lua、零 KOReader 依赖。

record0 开头是 16 字节 PalmDOC 头，偏移 12 的 u16 是 encryption（0 = 未加密）。

@module koplugin.book.utils.mobi
--]]

local Mobi = {}

--- record0 里的 encryption 字段。
---@param record0 string
---@return integer
function Mobi.encryption(record0)
    local a, b = record0:byte(13, 14)
    if not b then error("truncated MOBI record0") end
    return a * 256 + b
end

--- 文件是否 DRM 加密。不是 BOOKMOBI、读坏了、打不开都当未加密，交给打开流程自己报错。
---@param path string
---@return boolean
function Mobi.encrypted(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local ok, enc = pcall(function()
        local pdb = f:read(86) or ""
        if #pdb < 86 or pdb:sub(61, 68) ~= "BOOKMOBI" then return 0 end
        local a, b, c, d = pdb:byte(79, 82)
        f:seek("set", ((a * 256 + b) * 256 + c) * 256 + d)
        return Mobi.encryption(f:read(16) or "")
    end)
    f:close()
    return ok and enc ~= 0
end

return Mobi
