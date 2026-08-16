--[[--
文字处理工具：trim / 斜杠修剪 / BOM 与换行规范化 / XML 转义与实体解码 / URL 与 form 编码 / 纯文本段落化。

纯 Lua，零 KOReader 依赖（离线测试直接 require）。

@module koplugin.book.utils.text
--]]

local Text = {}

--- 去首尾空白；nil 视为空字符串。
---@param s any
---@return string
function Text.trim(s)
    return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

--- 只去尾部空白（保留行首缩进的场景用）。
---@param s any
---@return string
function Text.rtrim(s)
    return (tostring(s or ""):match("^(.-)%s*$"))
end

--- 去除全部空白（URL / 令牌等配置值里的粘贴残渣）。
---@param s any
---@return string
function Text.stripWhitespace(s)
    return (tostring(s or ""):gsub("%s+", ""))
end

--- 去首尾斜杠。
---@param s any
---@return string
function Text.trimSlashes(s)
    return (tostring(s or ""):gsub("^/+", ""):gsub("/+$", ""))
end

--- 只去尾部斜杠。
---@param s any
---@return string
function Text.rtrimSlashes(s)
    return (tostring(s or ""):gsub("/+$", ""))
end

--- 去 UTF-8 BOM。
---@param s any
---@return string
function Text.stripBom(s)
    return (tostring(s or ""):gsub("^\239\187\191", ""))
end

--- 换行符规范化：\r\n / \r → \n。
---@param s any
---@return string
function Text.normalizeNewlines(s)
    return (tostring(s or ""):gsub("\r\n", "\n"):gsub("\r", "\n"))
end

--- XML/HTML 特殊字符转义（& < > "）。
---@param s any
---@return string
function Text.xmlEscape(s)
    return (tostring(s or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

--- Unicode 码点 → UTF-8 字符串；超范围返回空串。
---@param cp number
---@return string
local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(
            0xF0 + math.floor(cp / 0x40000),
            0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40)
    end
    return ""
end

--- XML/HTML 实体解码：命名实体（lt/gt/quot/apos/amp）+ 十/十六进制数字实体。
---@param s any
---@return string
function Text.xmlDecode(s)
    s = tostring(s or "")
    s = s:gsub("&#(%d+);", function(n)
        return utf8char(tonumber(n) or 0)
    end)
    s = s:gsub("&#[xX](%x+);", function(n)
        return utf8char(tonumber(n, 16) or 0)
    end)
    return (s:gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", '"')
        :gsub("&apos;", "'")
        :gsub("&amp;", "&"))
end

--- URL 编码（RFC 3986 unreserved 保留，其余 %XX 大写）。
---@param value any
---@return string
function Text.urlEncode(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- URL 解码（%XX 解码，+ → 空格，form 语义）。
---@param s string|nil
---@return string|nil
function Text.urlDecode(s)
    if type(s) ~= "string" then
        return s
    end
    s = s:gsub("%+", " ")
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

--- 表 → application/x-www-form-urlencoded（键排序、跳过 nil 值、键值均 urlEncode）。
---@param tbl table|nil
---@return string
function Text.formEncode(tbl)
    local keys = {}
    for k in pairs(tbl or {}) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if v ~= nil then
            parts[#parts + 1] = Text.urlEncode(k) .. "=" .. Text.urlEncode(v)
        end
    end
    return table.concat(parts, "&")
end

--- 粗判是否已是 HTML 片段/文档。
---@param s string|nil
---@return boolean
function Text.looksLikeHtml(s)
    if type(s) ~= "string" then
        return false
    end
    local head = s:sub(1, 256):lower()
    return head:find("<html", 1, true) ~= nil
        or head:find("<!doctype", 1, true) ~= nil
        or head:find("<p", 1, true) ~= nil
        or head:find("<div", 1, true) ~= nil
        or head:find("<img", 1, true) ~= nil
        or head:find("<h%d") ~= nil
end

--- 纯文本按行包成 <p> 段落（规范化换行；行尾空白剥除；空行跳过；内容转义）。
---@param text string|nil
---@return string
function Text.textToBody(text)
    text = Text.normalizeNewlines(text)
    local parts = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = Text.rtrim(line)
        if line ~= "" then
            parts[#parts + 1] = "<p>" .. Text.xmlEscape(line) .. "</p>"
        end
    end
    return table.concat(parts, "\n")
end

return Text
