--[[--
双语对照的标记处理：找出叶子块、取原文、在块尾插入译文。纯 Lua，子进程里跑。

叶子块 = 块级元素里不再含块级元素的那一层（`<p>`、只装文字的 `<div>`、FB2 的 `<v>` 等），按出现顺序。
译文插在叶子块的闭合标签前（`<br/><span class="moon-tr" style="display:block">…</span>`），不新增兄弟元素：
原有元素的序号不变，原文 xpointer 在双语版里照样有效，进度与划线两版互通。
块级 span 让译文自成段落（和原文混在一个行内排版里，中英字体行高不同会压到上一行）；
关掉内嵌样式时 style 失效，靠 `<br/>` 退回换行。

只认标签名做线性扫描，不是 HTML 解析器：注释或属性值里的 `>` 会让个别段落漏翻，不会弄坏文档。

@module koplugin.book.features.translate.markup
--]]

local Text = require("utils.text")

local Markup = {}

--- 译文元素的 class；切回原文时据此认出落在译文里的位置。
Markup.CLASS = "moon-tr"

--- 源站已经嵌在章节里的译文节点（微信读书 `wr-translation`）。默认从原章去掉，双语对照再读回来。
Markup.EMBEDDED = "wr-translation"

--- 可以成为叶子块的元素。
local LEAF = {}
for name in ("p div li dt dd blockquote h1 h2 h3 h4 h5 h6 td th figcaption v subtitle text-author"):gmatch("%S+") do
    LEAF[name] = true
end

--- 只作分界的容器：出现在叶子块内部即说明外层不是叶子。
local BOUNDARY = {}
for name in ("html head body section article aside header footer nav main figure ul ol dl table thead tbody tfoot tr poem stanza epigraph cite annotation"):gmatch("%S+") do
    BOUNDARY[name] = true
end

--- 块内 HTML → 单行原文：去标签、解实体、折叠空白。
---@param inner string
---@return string
local function plain(inner)
    local s = Text.xmlDecode((inner:gsub("<[^>]*>", ""))):gsub("\194\160", " "):gsub("%s+", " ")
    return Text.trim(s)
end

--- 叶子块列表（只含有字母或非 ASCII 文字的块），按出现顺序。
---@param html string
---@return { text: string, open: integer, close: integer }[] open 为内容起点，close 为闭合标签 `</` 的位置
function Markup.blocks(html)
    local blocks = {}
    local open_name, open_end
    local in_nav = 0
    for at, slash, name, after in html:gmatch("()<(/?)([%w:%-]+)[^>]*>()") do
        name = name:lower():gsub("^.*:", "")
        if name == "nav" then
            -- 目录（nav.xhtml）的条目就是目录标题，插入译文会让阅读器认不出目录
            in_nav = math.max(0, in_nav + (slash == "/" and -1 or 1))
            open_name, open_end = nil, nil
        elseif in_nav == 0 and (LEAF[name] or BOUNDARY[name]) then
            if slash == "/" and open_name == name then
                local text = plain(html:sub(open_end, at - 1))
                if text:find("[%a\128-\255]") then
                    blocks[#blocks + 1] = { text = text, open = open_end, close = at }
                end
            end
            open_name, open_end = nil, nil
            if slash == "" and LEAF[name] and html:sub(after - 2, after - 2) ~= "/" then
                open_name, open_end = name, after
            end
        end
    end
    return blocks
end

--- 译文样式：颜色（`#RRGGBB`，空 = 跟随原文）与字号百分比（0 = 跟随原文）。
---@param translate { bilingual_color: string, bilingual_scale: integer }
---@return string|nil
function Markup.style(translate)
    local css = {}
    if translate.bilingual_color ~= "" then css[#css + 1] = "color:" .. translate.bilingual_color end
    if translate.bilingual_scale > 0 then css[#css + 1] = "font-size:" .. translate.bilingual_scale .. "%" end
    return #css > 0 and table.concat(css, ";") or nil
end

local ABBR = {}
for word in ("mr mrs ms dr prof sr jr st vs etc ie eg no vol pp fig"):gmatch("%S+") do
    ABBR[word] = true
end

local CJK_END = { ["。"] = true, ["！"] = true, ["？"] = true, ["…"] = true }

local function utf8Len(byte)
    if byte < 128 then return 1
    elseif byte < 224 then return 2
    elseif byte < 240 then return 3
    else return 4 end
end

local function collapse(text)
    return Text.trim((text:gsub("\194\160", " "):gsub("%s+", " ")))
end

--- 句末之后的引号、括号也算进这句。
---@param text string
---@param pos integer
---@return integer
local function closerLen(text, pos)
    local ascii = text:sub(pos, pos)
    if ascii == '"' or ascii == "'" or ascii == ")" or ascii == "]" then return 1 end
    local three = text:sub(pos, pos + 2)
    if three == "”" or three == "’" or three == "）" or three == "」" or three == "』" or three == "》" then
        return 3
    end
    return 0
end

--- 从标点起，把连着的句末标点和引号吃完，返回这句最后一个字节的位置。
---@param text string
---@param pos integer
---@return integer
local function skipTail(text, pos)
    local n = #text
    while pos <= n do
        local len = utf8Len(text:byte(pos))
        local ch = text:sub(pos, pos + len - 1)
        if ch == "." or ch == "!" or ch == "?" or CJK_END[ch] then
            pos = pos + len
        else
            local extra = closerLen(text, pos)
            if extra == 0 then break end
            pos = pos + extra
        end
    end
    return pos - 1
end

--- 段落拆成句子。没有句末标点时整段就是一句。
---@param text string
---@return { from: integer, to: integer }[]
local function sentenceRanges(text)
    local ranges, start_at = {}, 1
    local i, n = 1, #text
    while i <= n do
        local len = utf8Len(text:byte(i))
        local ch = text:sub(i, i + len - 1)
        local boundary = CJK_END[ch] or ch == "!" or ch == "?"
        if ch == "." then
            local prev, nxt = text:byte(i - 1), text:byte(i + 1)
            local decimal = prev and prev >= 48 and prev <= 57 and nxt and nxt >= 48 and nxt <= 57
            local word = text:sub(1, i - 1):match("([%a]+)$")
            local abbrev = word and (#word == 1 or ABBR[word:lower()])
            if not decimal and not abbrev and (nxt ~= 46) then
                local tail = skipTail(text, i)
                local after = text:byte(tail + 1)
                boundary = after == nil or after == 32 or after == 9 or after == 10 or after == 13
            end
        end
        if boundary then
            local tail = skipTail(text, i)
            if collapse(text:sub(start_at, tail)) ~= "" then
                ranges[#ranges + 1] = { from = start_at, to = tail }
            end
            local nxt = tail + 1
            while nxt <= n do
                local b = text:byte(nxt)
                if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 then break end
                nxt = nxt + 1
            end
            start_at, i = nxt, nxt
        else
            i = i + len
        end
    end
    if start_at <= n and collapse(text:sub(start_at)) ~= "" then
        ranges[#ranges + 1] = { from = start_at, to = n }
    end
    return ranges
end

--- 块内 HTML 解成纯文本，记下每个纯文本字节结束处在 HTML 里的位置。
---@param inner string
---@return string
---@return integer[]
local function decodeMap(inner)
    local parts, at = {}, {}
    local i, n, plen = 1, #inner, 0
    while i <= n do
        local b = inner:byte(i)
        if b == 60 then
            local gt = inner:find(">", i, true)
            if not gt then break end
            i = gt + 1
        elseif b == 38 then
            local semi = inner:find(";", i, true)
            if semi and semi - i <= 10 then
                local decoded = Text.xmlDecode(inner:sub(i, semi))
                parts[#parts + 1] = decoded
                plen = plen + #decoded
                at[plen] = semi + 1
                i = semi + 1
            else
                parts[#parts + 1] = "&"
                plen = plen + 1
                at[plen] = i + 1
                i = i + 1
            end
        else
            local len = utf8Len(b)
            if i + len - 1 > n then len = 1 end
            parts[#parts + 1] = inner:sub(i, i + len - 1)
            plen = plen + len
            at[plen] = i + len
            i = i + len
        end
    end
    return table.concat(parts), at
end

--- 一块里要翻译的文本，以及译文插在块内 HTML 的位置（插在该下标之前）。
--- `paragraph`（默认）整段一条，插在段尾。`sentence` 按句末标点拆开，插在该句标点之后。
---@param inner string
---@param unit "paragraph"|"sentence"|nil
---@return { key: string, at: integer }[]
function Markup.points(inner, unit)
    local whole = plain(inner)
    if whole == "" then return {} end
    if unit ~= "sentence" then return { { key = whole, at = #inner + 1 } } end
    local decoded, at = decodeMap(inner)
    local points = {}
    for _idx, range in ipairs(sentenceRanges(decoded)) do
        local key = collapse(decoded:sub(range.from, range.to))
        local html_at = at[range.to]
        if html_at and key:find("[%a\128-\255]") then
            points[#points + 1] = { key = key, at = html_at }
        end
    end
    if #points == 0 then return { { key = whole, at = #inner + 1 } } end
    return points
end

--- 在每个有译文的叶子块里插入译文。
--- 按段落时插在段尾；按句子时插在句末标点后。都在原块内部，不新增兄弟元素。
--- 原文已是目标语言时译文只多出几个空白（Edge 会在中文句号后补空格），不算译文，不插。
---@param html string
---@param lookup table<string, string> 原文 → 译文
---@param style string|nil 译文的附加内嵌样式（`color:#555555;font-size:90%;`），nil 跟随原文
---@param unit "paragraph"|"sentence"|nil 缺省按段落
---@return string html
---@return integer count 插入的段数
function Markup.inject(html, lookup, style, unit)
    local open = '<br/><span class="' .. Markup.CLASS .. '" style="display:block' .. (style and (";" .. style) or "") .. '">'
    local out, pos, count = {}, 1, 0
    for _idx, block in ipairs(Markup.blocks(html)) do
        local inner = html:sub(block.open, block.close - 1)
        local points = Markup.points(inner, unit)
        local parts, cursor = {}, #inner + 1
        for index = #points, 1, -1 do
            local point = points[index]
            local translated = lookup[point.key]
            parts[#parts + 1] = inner:sub(point.at, cursor - 1)
            if translated and translated:gsub("%s+", "") ~= point.key:gsub("%s+", "") then
                parts[#parts + 1] = open .. Text.xmlEscape(translated) .. "</span>"
                count = count + 1
            end
            cursor = point.at
        end
        parts[#parts + 1] = inner:sub(1, cursor - 1)
        out[#out + 1] = html:sub(pos, block.open - 1)
        for index = #parts, 1, -1 do out[#out + 1] = parts[index] end
        pos = block.close
    end
    out[#out + 1] = html:sub(pos)
    return table.concat(out), count
end

--- class 属性里有没有独立的译文节点标记。
---@param attrs string
---@return boolean
local function embeddedClass(attrs)
    local class = attrs:match('class="([^"]*)"')
    if not class then return false end
    for token in class:gmatch("%S+") do
        if token == Markup.EMBEDDED then return true end
    end
    return false
end

--- 正文里是否有源站译文节点。
---@param html string
---@return boolean
function Markup.hasEmbedded(html)
    return type(html) == "string" and html:find(Markup.EMBEDDED, 1, true) ~= nil
end

local EMBEDDED_SPAN = '<br/><span class="' .. Markup.CLASS .. '" style="display:block">'

--- 拆开源站译文：原文版去掉译文节点；双语版把译文收进前一个元素，和 Edge 生成的 `moon-tr` 一样。
--- 没有译文节点时第二返回值是 nil，第一返回值就是原文。
---@param html string
---@return string plain
---@return string|nil bilingual
function Markup.splitEmbedded(html)
    if not Markup.hasEmbedded(html) then return html, nil end
    html = html:gsub('<link[^>]-wrtranslation%.css[^>]*>%s*', "")
    local plain, rich, held, gap_held, absorbed = {}, {}, nil, "", false
    local function emit(text)
        plain[#plain + 1] = text
        rich[#rich + 1] = text
    end
    local function flush()
        if not held then return end
        emit(held)
        held = nil
        if gap_held ~= "" then
            emit(gap_held)
            gap_held = ""
        end
    end
    local i, n = 1, #html
    while i <= n do
        local start, finish, slash, tag, attrs = html:find("<(/?)([%w:]+)([^>]*)>", i)
        if not start then
            flush()
            emit(html:sub(i))
            break
        end
        local gap = html:sub(i, start - 1)
        if gap ~= "" then
            if held and not gap:find("%S") then
                gap_held = gap_held .. gap
            else
                flush()
                emit(gap)
            end
        end
        if slash == "/" then
            flush()
            held = html:sub(start, finish)
            i = finish + 1
        elseif embeddedClass(attrs) then
            local close_at = html:find("</" .. tag .. ">", finish + 1, true)
            local inner = close_at and html:sub(finish + 1, close_at - 1) or ""
            if held and inner ~= "" then
                rich[#rich + 1] = EMBEDDED_SPAN .. inner .. "</span>"
                absorbed = true
            end
            flush()
            i = close_at and (close_at + #tag + 3) or (finish + 1)
        else
            flush()
            emit(html:sub(start, finish))
            i = finish + 1
        end
    end
    flush()
    if not absorbed then return html, nil end
    return table.concat(plain), table.concat(rich)
end

--- 去掉源站译文节点和它的样式表引用。原文节点不动。
---@param html string
---@return string
function Markup.stripEmbedded(html)
    return (Markup.splitEmbedded(html))
end

return Markup
