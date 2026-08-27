--[[--
微信读书划线 HTML 注入（rune range，对齐网页端）。

@module koplugin.book.source.wechat.annotations
--]]

local Annotations = {}

local UNDERLINE_CSS = ".wr-underline{border-bottom:2px dashed #ff6b35;padding-bottom:2px;}"

local function toRunes(str)
    local runes, i, len = {}, 1, #str
    while i <= len do
        local byte = str:byte(i)
        local width = byte < 0x80 and 1 or byte < 0xe0 and 2 or byte < 0xf0 and 3 or 4
        runes[#runes + 1] = str:sub(i, i + width - 1)
        i = i + width
    end
    return runes
end

local function parseRange(range_str)
    if type(range_str) ~= "string" then return nil end
    local a, b = range_str:match("^(%d+)%-(%d+)$")
    if not a then return nil end
    return tonumber(a) + 1, tonumber(b) + 1
end

--- 把划线注入 HTML/XHTML 正文。
---@param html string
---@param underlines table[]|nil
---@return string html, string css
function Annotations.inject(html, underlines)
    if type(html) ~= "string" or html == "" or type(underlines) ~= "table" then
        return html, ""
    end
    local ranges = {}
    for _, ul in ipairs(underlines) do
        if type(ul) == "table" and ul.range then
            local start_pos, end_pos = parseRange(tostring(ul.range))
            if start_pos and end_pos and end_pos > start_pos then
                ranges[#ranges + 1] = { start_pos, end_pos }
            end
        end
    end
    if #ranges == 0 then return html, "" end
    table.sort(ranges, function(a, b) return a[1] > b[1] end)
    local runes = toRunes(html)
    for _, range in ipairs(ranges) do
        local start_pos, end_pos = range[1], range[2]
        if end_pos <= #runes then
            local parts = {}
            for i = 1, start_pos - 1 do parts[#parts + 1] = runes[i] end
            parts[#parts + 1] = '<span class="wr-underline">'
            for i = start_pos, end_pos - 1 do parts[#parts + 1] = runes[i] end
            parts[#parts + 1] = '</span>'
            for i = end_pos, #runes do parts[#parts + 1] = runes[i] end
            runes = parts
        end
    end
    return table.concat(runes), UNDERLINE_CSS
end

return Annotations
