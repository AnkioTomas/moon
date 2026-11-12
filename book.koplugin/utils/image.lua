--[[--
图片后缀与文件头。纯 Lua，零 KOReader 依赖。

@module koplugin.book.utils.image
--]]

local Image = {}

--- 缓存探测顺序；.jpeg 与 .jpg 都会查。
Image.SUFFIXES = { ".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg" }

local MIME = {
    [".jpg"] = "image/jpeg",
    [".jpeg"] = "image/jpeg",
    [".png"] = "image/png",
    [".gif"] = "image/gif",
    [".webp"] = "image/webp",
    [".svg"] = "image/svg+xml",
    [".bmp"] = "image/bmp",
}

local KNOWN = {}
for _idx, ext in ipairs(Image.SUFFIXES) do
    KNOWN[ext] = true
end
KNOWN[".bmp"] = true

---@param data string
---@param i integer
---@return integer
local function be16(data, i)
    return data:byte(i) * 256 + data:byte(i + 1)
end

---@param data string
---@param i integer
---@return integer
local function be32(data, i)
    return be16(data, i) * 65536 + be16(data, i + 2)
end

---@param data string
---@param i integer
---@return integer
local function le16(data, i)
    return data:byte(i) + data:byte(i + 1) * 256
end

---@param data string
---@param i integer
---@return integer
local function le24(data, i)
    return data:byte(i) + data:byte(i + 1) * 256 + data:byte(i + 2) * 65536
end

---@param data string
---@param i integer
---@return integer
local function le32(data, i)
    return le16(data, i) + le16(data, i + 2) * 65536
end

--- JPEG SOF 宽高；找不到或头被截断时返回 nil。
---@param data string
---@return integer|nil w
---@return integer|nil h
local function jpegSize(data)
    local i, n = 3, #data
    while i < n do
        if data:byte(i) ~= 255 then
            i = i + 1
        else
            while i <= n and data:byte(i) == 255 do
                i = i + 1
            end
            if i > n then break end
            local marker = data:byte(i)
            i = i + 1
            if marker == 216 or marker == 217 or marker == 1 or (marker >= 208 and marker <= 215) then
                -- SOI/EOI/TEM/RST：没有长度字段
            elseif marker == 218 then
                break
            elseif marker >= 192 and marker <= 207 and marker ~= 196 and marker ~= 200 and marker ~= 204 then
                if i + 6 > n then return nil end
                local h, w = be16(data, i + 3), be16(data, i + 5)
                if w > 0 and h > 0 then return w, h end
                return nil
            else
                if i + 1 > n then return nil end
                local len = be16(data, i)
                if len < 2 then return nil end
                i = i + len
            end
        end
    end
    return nil
end

--- WebP VP8 / VP8L / VP8X 画布尺寸。
---@param data string
---@return integer|nil w
---@return integer|nil h
local function webpSize(data)
    local kind = data:sub(13, 16)
    if kind == "VP8X" and #data >= 30 then
        return le24(data, 25) + 1, le24(data, 28) + 1
    end
    if kind == "VP8L" and #data >= 25 and data:byte(21) == 47 then
        local bits = le32(data, 22)
        return bits % 16384 + 1, math.floor(bits / 16384) % 16384 + 1
    end
    if kind == "VP8 " and #data >= 30 then
        local i = 21
        while i + 9 <= #data do
            if data:byte(i) == 157 and data:byte(i + 1) == 1 and data:byte(i + 2) == 42 then
                return le16(data, i + 3) % 16384, le16(data, i + 5) % 16384
            end
            i = i + 1
        end
    end
    return nil
end

--- 路径或 URL 的已知图片后缀。jpeg 归一成 .jpg。
---@param name string|nil
---@return string|nil
function Image.suffix(name)
    if type(name) ~= "string" or name == "" then return nil end
    local path = name:match("^[^%?#]+") or name
    local raw = path:match("%.([%w]+)$")
    if not raw then return nil end
    raw = "." .. raw:lower()
    if not KNOWN[raw] then return nil end
    if raw == ".jpeg" then return ".jpg" end
    return raw
end

--- 按文件头识别后缀。第二返回值是 MIME。
---@param data string|nil
---@return string|nil ext
---@return string|nil mime
function Image.ext(data)
    if type(data) ~= "string" or #data < 3 then return nil end
    local ext
    if data:sub(1, 3) == "\255\216\255" then
        ext = ".jpg"
    elseif #data >= 8 and data:sub(1, 8) == "\137PNG\r\n\26\n" then
        ext = ".png"
    elseif #data >= 6 and (data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a") then
        ext = ".gif"
    elseif #data >= 12 and data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        ext = ".webp"
    elseif data:sub(1, 2) == "BM" then
        ext = ".bmp"
    else
        local lower = data:sub(1, 256):lower()
        if lower:find("<svg", 1, true) or lower:find("<?xml", 1, true) then
            ext = ".svg"
        end
    end
    if not ext then return nil end
    return ext, MIME[ext]
end

--- 从已读到的字节里解析宽高；头不完整或无法识别时返回 nil。
---@param data string|nil
---@return integer|nil w
---@return integer|nil h
function Image.size(data)
    if type(data) ~= "string" or #data < 6 then return nil end
    if #data >= 24 and data:sub(1, 8) == "\137PNG\r\n\26\n" and data:sub(13, 16) == "IHDR" then
        local w, h = be32(data, 17), be32(data, 21)
        if w > 0 and h > 0 then return w, h end
        return nil
    end
    if data:sub(1, 3) == "\255\216\255" then
        return jpegSize(data)
    end
    if #data >= 10 and (data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a") then
        local w, h = le16(data, 7), le16(data, 9)
        if w > 0 and h > 0 then return w, h end
        return nil
    end
    if #data >= 26 and data:sub(1, 2) == "BM" then
        local w, h = le32(data, 19), le32(data, 23)
        if h >= 0x80000000 then h = 0x100000000 - h end
        if w > 0 and h > 0 then return w, h end
        return nil
    end
    if #data >= 16 and data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        local w, h = webpSize(data)
        if w and h and w > 0 and h > 0 then return w, h end
        return nil
    end
    return nil
end

--- 打开文件读头解析宽高；JPEG 头可能较靠后，最多再读到 1MB。
---@param path string|nil
---@return integer|nil w
---@return integer|nil h
function Image.dimensions(path)
    if type(path) ~= "string" or path == "" then return nil end
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local data = handle:read(65536) or ""
    local w, h = Image.size(data)
    if not w and #data >= 65536 then
        local more = handle:read((1024 * 1024) - #data)
        if more and #more > 0 then
            w, h = Image.size(data .. more)
        end
    end
    handle:close()
    return w, h
end

--- 阅读器解不了的图片格式（ISO BMFF 容器：AVIF / HEIC）。返回格式名，其它返回 nil。
---@param data string|nil
---@return string|nil
function Image.unsupported(data)
    if type(data) ~= "string" or #data < 12 or data:sub(5, 8) ~= "ftyp" then return nil end
    local brand = data:sub(9, 12)
    if brand == "avif" or brand == "avis" then return "AVIF" end
    if brand == "heic" or brand == "heix" or brand == "mif1" or brand == "msf1" then return "HEIC" end
    return nil
end

--- 打开文件读头；是图返回后缀。
---@param path string|nil
---@return string|nil ext
---@return string|nil mime
function Image.file(path)
    if type(path) ~= "string" or path == "" then return nil end
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local head = handle:read(256) or ""
    handle:close()
    return Image.ext(head)
end

--- 文件头是已知图片。
---@param path string|nil
---@return boolean
function Image.ok(path)
    return Image.file(path) ~= nil
end

---@param ext string|nil
---@return string|nil
function Image.mime(ext)
    return MIME[ext]
end

return Image
