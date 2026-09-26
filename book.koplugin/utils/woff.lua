--[[--
WOFF 1.0 → sfnt（TTF/OTF）解包。

FreeType 打开 WOFF 时会把整份字体解压到堆上，而 crengine 每个字号/字重实例各开一个 FT_Face：
30MB 级的 CJK 字体开十几个实例就能把 512MB 的设备撑爆。sfnt 文件由 FreeType mmap，实例间共享页缓存。

@module koplugin.book.utils.woff
--]]

local Woff = {}

local HEADER_SIZE = 44
local ENTRY_SIZE = 20

---@param s string
---@param pos integer 1 起始
---@return integer
local function u32(s, pos)
    local a, b, c, d = s:byte(pos, pos + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

---@param s string
---@param pos integer 1 起始
---@return integer
local function u16(s, pos)
    local a, b = s:byte(pos, pos + 1)
    return a * 256 + b
end

---@param n integer
---@return string
local function be32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end

---@param n integer
---@return string
local function be16(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

---@param n integer
---@return string
local function pad4(n)
    return ("\0"):rep((4 - n % 4) % 4)
end

--- 解析 WOFF 表目录；目录按 tag 升序（规范要求），原样沿用为 sfnt 表记录顺序。
---@param data string
---@return { tag: string, offset: integer, comp_len: integer, orig_len: integer, checksum: integer }[]|nil
---@return string|nil err
local function readDirectory(data)
    if #data < HEADER_SIZE or data:sub(1, 4) ~= "wOFF" then
        return nil, "not a WOFF 1.0 file"
    end
    local num = u16(data, 13)
    if num == 0 or #data < HEADER_SIZE + num * ENTRY_SIZE then
        return nil, "truncated WOFF directory"
    end
    local entries = {}
    for i = 0, num - 1 do
        local p = HEADER_SIZE + 1 + i * ENTRY_SIZE
        local entry = {
            tag = data:sub(p, p + 3),
            offset = u32(data, p + 4),
            comp_len = u32(data, p + 8),
            orig_len = u32(data, p + 12),
            checksum = u32(data, p + 16),
        }
        if entry.comp_len > entry.orig_len or entry.offset + entry.comp_len > #data then
            return nil, "invalid WOFF table " .. entry.tag
        end
        entries[#entries + 1] = entry
    end
    return entries
end

---@param entries table
---@param flavor string sfnt 版本（4 字节）
---@return string
local function sfntHeader(entries, flavor)
    local num = #entries
    local selector = 0
    while 2 ^ (selector + 1) <= num do selector = selector + 1 end
    local range = 2 ^ selector * 16
    local out = { flavor, be16(num), be16(range), be16(selector), be16(num * 16 - range) }
    local offset = 12 + 16 * num
    for _, e in ipairs(entries) do
        out[#out + 1] = e.tag .. be32(e.checksum) .. be32(offset) .. be32(e.orig_len)
        offset = offset + e.orig_len + #pad4(e.orig_len)
    end
    return table.concat(out)
end

---@param data string
---@param e table 表目录项
---@return string|nil table_data
---@return string|nil err
local function tableData(data, e)
    local raw = data:sub(e.offset + 1, e.offset + e.comp_len)
    if e.comp_len == e.orig_len then return raw end
    -- ffi/zlib 解压失败直接 assert；损坏的表要转成错误返回，调用方会退回原 WOFF。
    local ok, out = pcall(require("ffi/zlib").zlib_uncompress, raw, e.orig_len)
    if not ok or #out ~= e.orig_len then
        return nil, "corrupt WOFF table " .. e.tag
    end
    return out
end

--- 把 WOFF 1.0 文件转成 sfnt 写到 dest（先写 .part 再改名，失败不留半截文件）。
--- 逐表解压写盘，峰值内存 ≈ 源文件 + 最大单表。
---@param src string WOFF 路径
---@param dest string 输出路径
---@return boolean|nil ok
---@return string|nil err
function Woff.toSfnt(src, dest)
    local f, open_err = io.open(src, "rb")
    if not f then return nil, open_err end
    local data = f:read("*a")
    f:close()
    local entries, err = readDirectory(data)
    if not entries then return nil, err end

    local part = dest .. ".part"
    local out
    out, err = io.open(part, "wb")
    if not out then return nil, err end
    local ok = out:write(sfntHeader(entries, data:sub(5, 8)))
    for _, e in ipairs(entries) do
        if not ok then break end
        local chunk
        chunk, err = tableData(data, e)
        ok = chunk and out:write(chunk, pad4(e.orig_len))
    end
    ok = out:close() and ok
    if not (ok and os.rename(part, dest)) then
        os.remove(part)
        return nil, err or "failed to write sfnt"
    end
    return true
end

return Woff
