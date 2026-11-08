--[[--
盐选章节字体还原。只替换 HTML 文本节点，保留图片、段落和属性。

字体写临时文件供 FreeType 读取，识别放在子进程；完成、失败或取消均由父进程清理。
只复用通用字形识别，不使用其它书源的正文规则。

@module source.zhihu.font
--]]

local Glyph = require("utils.glyph")
local Text = require("utils.text")
local _ = require("l10n").get("source.zhihu")

local Font = {}

local function restore(wire, font_path)
    local font = type(wire.font) == "table" and wire.font.base64
    local encoded = type(font) == "string" and font:match("^data:font/ttf;[^,]*;base64,(.+)$")
    if not encoded then return { err = _("知乎章节字体还原失败，请重试") } end
    local bytes = Text.base64Decode(encoded)
    if bytes:sub(1, 4) ~= "\0\1\0\0" then return { err = _("知乎章节字体还原失败，请重试") } end
    local file = assert(io.open(font_path, "wb"))
    assert(file:write(bytes))
    assert(file:close())

    local codes, seen = {}, {}
    for ch in Text.xmlDecode(wire.manuscript):gmatch(Text.UTF8_CHAR) do
        local cp = Glyph.codepoint(ch)
        if cp > 127 and not seen[cp] then
            seen[cp] = true
            codes[#codes + 1] = cp
        end
    end
    table.sort(codes)
    local ref = require("fontlist").fontdir .. "/noto/NotoSansCJKsc-Regular.otf"
    local reference = assert(io.open(ref, "rb"))
    local size = reference:seek("end")
    reference:close()
    local cache = require("utils.paths").cacheDir() .. "/glyph_v1_" .. size .. ".bin"
    local map = Glyph.recognize(ref, cache, { { font_path = font_path, codes = codes, limit = 6763 } })[1]
    for cp, char in pairs(map) do
        if char == false then
            require("utils.log").warn("zhihu font glyph not recognized", cp)
            return { err = _("知乎章节字体还原失败，请重试") }
        end
    end
    local function textNode(node)
        local text = Text.xmlDecode(node):gsub(Text.UTF8_CHAR, function(ch)
            return map[Glyph.codepoint(ch)]
        end)
        return Text.xmlEscape(text)
    end
    local parts, pos = {}, 1
    for first, after in wire.manuscript:gmatch("()<[^>]*>()") do
        parts[#parts + 1] = textNode(wire.manuscript:sub(pos, first - 1))
        parts[#parts + 1] = wire.manuscript:sub(first, after - 1)
        pos = after
    end
    parts[#parts + 1] = textNode(wire.manuscript:sub(pos))
    return { html = table.concat(parts) }
end

---@param wire table 正文接口数据，use_font=true
---@param cb fun(html: string|nil, err: string|nil)
---@return BookJob
function Font.restoreAsync(wire, cb)
    local path = os.tmpname()
    return require("workers.job").run(function()
        return restore(wire, path)
    end, {
        name = "zhihu_font",
        kind = "light",
        timeout = 600,
        on_done = function(result)
            os.remove(path)
            cb(result.html, result.err)
        end,
        on_failed = function(err)
            os.remove(path)
            cb(nil, tostring(err))
        end,
        on_cancelled = function() os.remove(path) end,
    })
end

return Font
