--[[--
网页 / 订阅正文转 UTF-8。声明编码取 BOM > HTTP 头 > XML 声明 / meta，非 UTF-8 的交系统 iconv。

设备上的 iconv 由 libc 提供，缺哪个编码就如实报错，不把乱码当正文往下传。

@module koplugin.book.utils.charset
--]]

local ffi = require("ffi")

local Charset = {}

ffi.cdef [[
typedef void *iconv_t;
iconv_t iconv_open(const char *tocode, const char *fromcode);
size_t iconv(iconv_t cd, char **inbuf, size_t *inleft, char **outbuf, size_t *outleft);
int iconv_close(iconv_t cd);
]]

local lib
--- glibc / bionic 在 libc 里；macOS 的在 libiconv。
local function iconvLib()
    if lib == nil then
        lib = false
        if pcall(function() return ffi.C.iconv_open end) then
            lib = ffi.C
        else
            local ok, loaded = pcall(ffi.load, "iconv")
            if ok then lib = loaded end
        end
    end
    return lib
end

--- GB2312 / GBK 都按超集 GB18030 解。
local ALIAS = { gb2312 = "GB18030", gbk = "GB18030", ["gb-2312"] = "GB18030", x_gbk = "GB18030", gb18030 = "GB18030" }

--- 声明的编码名；没声明返回 nil。
---@param body string
---@param content_type string|nil
---@return string|nil
function Charset.detect(body, content_type)
    local head = body:sub(1, 4)
    if head:sub(1, 3) == "\239\187\191" then return "utf-8" end
    if head:sub(1, 2) == "\255\254" or head:sub(1, 2) == "\254\255" then return "utf-16" end
    local name = tostring(content_type or ""):match("[Cc][Hh][Aa][Rr][Ss][Ee][Tt]%s*=%s*[\"']?([%w_%-:]+)")
    if not name then
        local top = body:sub(1, 2048)
        name = top:match("^%s*<%?xml[^>]-encoding%s*=%s*[\"']([%w_%-]+)")
            or top:match("<[Mm][Ee][Tt][Aa][^>]-[Cc][Hh][Aa][Rr][Ss][Ee][Tt]%s*=%s*[\"']?([%w_%-]+)")
    end
    return name and name:lower() or nil
end

--- 整段转 UTF-8，坏字节跳过。
---@param body string
---@param from string iconv 编码名
---@return string|nil
local function convert(body, from)
    local iconv = iconvLib()
    if not iconv then return nil end
    local cd = iconv.iconv_open("UTF-8", from)
    if tonumber(ffi.cast("intptr_t", cd)) == -1 then return nil end
    local n = #body
    -- 任何常见编码转 UTF-8 最多 3 倍。
    local cap = n * 3 + 16
    local inbuf, outbuf = ffi.new("char[?]", n + 1), ffi.new("char[?]", cap)
    ffi.copy(inbuf, body, n)
    local inp, inleft = ffi.new("char*[1]", inbuf), ffi.new("size_t[1]", n)
    local outp, outleft = ffi.new("char*[1]", outbuf), ffi.new("size_t[1]", cap)
    local failed = ffi.cast("size_t", -1)
    while inleft[0] > 0 do
        if iconv.iconv(cd, inp, inleft, outp, outleft) ~= failed then break end
        inp[0], inleft[0] = inp[0] + 1, inleft[0] - 1
    end
    iconv.iconv(cd, nil, nil, outp, outleft)
    iconv.iconv_close(cd)
    return ffi.string(outbuf, cap - tonumber(outleft[0]))
end

--- 转成 UTF-8（去 BOM）。UTF-8 / ASCII / 没声明的原样返回；转不了返回 nil 与编码名。
---@param body string
---@param content_type string|nil HTTP Content-Type
---@return string|nil text
---@return string|nil charset 转不了的编码名
function Charset.toUtf8(body, content_type)
    local name = Charset.detect(body, content_type)
    if not name or name == "utf-8" or name == "utf8" or name == "us-ascii" or name == "ascii" then
        return (body:gsub("^\239\187\191", ""))
    end
    local text = convert(body, ALIAS[name] or name)
    if not text then return nil, name end
    return text
end

return Charset
