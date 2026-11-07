--[[--
塔读正文按精确字形指纹还原 Unicode。轮廓起点及排列顺序不影响指纹；
索引只含哈希与码点，不含原字体。仅替换文本节点，未知字形拒绝缓存。

@module source.tadu.font
--]]

require("l10n").apply()
local Glyph = require("utils.glyph")
local Text = require("utils.text")
local _ = require("gettext")
local TABLE_PATH = debug.getinfo(1, "S").source:sub(2):match("^(.*)/") .. "/font_table.bin"
-- MTF1 + sorted records: 32-byte SHA-256, 3-byte big-endian Unicode codepoint.
local RECORD_SIZE = 35

local Font = {}

local function findCodepoint(index, hash)
    local key = hash:gsub("%x%x", function(hex) return string.char(tonumber(hex, 16)) end)
    local low, high = 0, (#index - 4) / RECORD_SIZE - 1
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local pos = 5 + mid * RECORD_SIZE
        local candidate = index:sub(pos, pos + 31)
        if candidate == key then
            local a, b, c = index:byte(pos + 32, pos + 34)
            return a * 65536 + b * 256 + c
        elseif candidate < key then
            low = mid + 1
        else
            high = mid - 1
        end
    end
end

local function fingerprint(outline, advance)
    local paths, begin = {}, 0
    for contour = 0, outline.n_contours - 1 do
        local points = {}
        local last = tonumber(outline.contours[contour])
        for i = begin, last do
            local point = outline.points[i]
            points[#points + 1] = string.format("%d,%d,%d", tonumber(outline.tags[i]) % 2,
                math.floor(tonumber(point.x) / 64 + 0.5), math.floor(tonumber(point.y) / 64 + 0.5))
        end
        local best
        for i = 1, #points do
            local rotated = {}
            for j = 0, #points - 1 do rotated[#rotated + 1] = points[(i + j - 1) % #points + 1] end
            local value = table.concat(rotated, ";")
            if not best or value < best then best = value end
        end
        paths[#paths + 1] = best
        begin = last + 1
    end
    table.sort(paths)
    local shape = math.floor(tonumber(advance) / 64 + 0.5) .. "|" .. table.concat(paths, "|")
    return require("ffi/sha2").sha256(shape)
end

local function restore(html, bytes, path)
    if bytes:sub(1, 4) ~= "\0\1\0\0" then return { err = _("塔读章节字体还原失败，请重试") } end
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes))
    assert(file:close())
    local index_file = assert(io.open(TABLE_PATH, "rb"))
    local index = assert(index_file:read("*a"))
    assert(index_file:close())
    assert(index:sub(1, 4) == "MTF1" and (#index - 4) % RECORD_SIZE == 0, "invalid tadu font index")
    local font = require("ffi/freetype").newFaceSize(path, 2048) --[[@as FreeTypeSize]]
    local ft2 = assert(require("ffi").loadlib)("freetype", "6")
    local map, seen = {}, {}
    local parts, nodes, pos = {}, {}, 1
    local function textNode(node)
        local text = Text.xmlDecode(node)
        parts[#parts + 1] = text
        nodes[#nodes + 1] = #parts
    end
    for first, after in html:gmatch("()<[^>]*>()") do
        textNode(html:sub(pos, first - 1))
        parts[#parts + 1] = html:sub(first, after - 1)
        pos = after
    end
    textNode(html:sub(pos))
    for _node_idx, part in ipairs(nodes) do
        for ch in parts[part]:gmatch(Text.UTF8_CHAR) do
            local cp = Glyph.codepoint(ch)
            if cp > 127 and not seen[cp] then
                seen[cp] = true
                if font:hasGlyph(cp) then
                    -- FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP: design outlines, not screen pixels.
                    assert(ft2.FT_Load_Char(font.face, cp, 10) == 0, "FreeType glyph load failed")
                    local glyph = font.face.glyph
                    if glyph.outline.n_points > 0 then
                        local decoded = findCodepoint(index, fingerprint(glyph.outline, glyph.advance.x))
                        if not decoded then
                            font:done()
                            require("utils.log").warn("tadu font glyph not mapped", cp)
                            return { err = _("塔读章节字体还原失败，请重试") }
                        end
                        map[cp] = Text.utf8char(decoded)
                    end
                end
            end
        end
    end
    font:done()
    for _node_idx, part in ipairs(nodes) do
        parts[part] = Text.xmlEscape(parts[part]:gsub(Text.UTF8_CHAR, function(ch)
            return map[Glyph.codepoint(ch)]
        end))
    end
    return { html = table.concat(parts) }
end

---@param html string
---@param bytes string
---@param cb fun(html: string|nil, err: string|nil)
---@return BookJob
function Font.restoreAsync(html, bytes, cb)
    local path = os.tmpname()
    return require("workers.job").run(function()
        return restore(html, bytes, path)
    end, {
        name = "tadu_font", kind = "light", timeout = 30,
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
