--[[--
MOBI 族（mobi / azw / azw3）文件头的最小读取：DRM 加密标记、EXTH 201 指向的封面图。纯 Lua、零 KOReader 依赖。

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

local function u16(s, o) local a, b = s:byte(o + 1, o + 2); return a * 256 + b end
local function u32(s, o) local a, b, c, d = s:byte(o + 1, o + 4); return ((a * 256 + b) * 256 + c) * 256 + d end

--- EXTH 201（封面在图片记录里的偏移）指向的那条记录。
--- crengine 自己也读 MOBI 封面，但只认 JFIF（FF D8 FF E0）的 JPEG：EXIF / 量化表开头（FF D8 FF E1 / DB）
--- 的封面它不登记，于是没封面。这里按 EXTH 直接取记录，不看图片子格式。
--- 不是 BOOKMOBI、没有 EXTH / 201、记录不像图片都返回 nil。
---@param path string
---@return string|nil data 图片字节
function Mobi.cover(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local ok, data = pcall(function()
        local head = f:read(78) or ""
        if #head < 78 or head:sub(61, 68) ~= "BOOKMOBI" then return nil end
        local count = u16(head, 76)
        local table_ = f:read(count * 8) or ""
        if #table_ < count * 8 then return nil end
        local function offset(i) return u32(table_, i * 8) end
        local size = f:seek("end")
        local function record(i)
            if i < 0 or i >= count then return nil end
            local from = offset(i)
            local to = i + 1 < count and offset(i + 1) or size
            if to <= from then return nil end
            f:seek("set", from)
            return f:read(to - from)
        end
        local r0 = record(0)
        if not r0 or #r0 < 0x84 or r0:sub(17, 20) ~= "MOBI" then return nil end
        local first_image = u32(r0, 0x6C)
        if first_image == 0xFFFFFFFF or u32(r0, 0x80) % 0x80 < 0x40 then return nil end
        local pos = 16 + u32(r0, 20)
        if r0:sub(pos + 1, pos + 4) ~= "EXTH" then return nil end
        local p = pos + 12
        for _i = 1, u32(r0, pos + 8) do
            if p + 8 > #r0 then break end
            local typ, len = u32(r0, p), u32(r0, p + 4)
            if len < 8 or p + len > #r0 then break end
            if typ == 201 and len >= 12 then
                local img = record(first_image + u32(r0, p + 8))
                if not img then return nil end
                local b1, b2, b3 = img:byte(1, 3)
                if (b1 == 0xFF and b2 == 0xD8) or (b1 == 0x89 and b2 == 0x50) or (b1 == 0x47 and b2 == 0x49 and b3 == 0x46) then
                    return img
                end
                return nil
            end
            p = p + len
        end
    end)
    f:close()
    return ok and data or nil
end

return Mobi
