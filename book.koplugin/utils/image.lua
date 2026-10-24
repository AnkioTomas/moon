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
