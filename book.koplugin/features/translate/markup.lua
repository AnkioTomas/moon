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
    local s = Text.xmlDecode((inner:gsub("<[^>]*>", ""))):gsub("&nbsp;", " "):gsub("%s+", " ")
    return Text.trim(s)
end

--- 叶子块列表（只含有字母或非 ASCII 文字的块），按出现顺序。
---@param html string
---@return { text: string, close: integer }[] close 为闭合标签 `</` 的位置
function Markup.blocks(html)
    local blocks = {}
    local open_name, open_end
    for at, slash, name, after in html:gmatch("()<(/?)([%w:%-]+)[^>]*>()") do
        name = name:lower():gsub("^.*:", "")
        if LEAF[name] or BOUNDARY[name] then
            if slash == "/" and open_name == name then
                local text = plain(html:sub(open_end, at - 1))
                if text:find("[%a\128-\255]") then
                    blocks[#blocks + 1] = { text = text, close = at }
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

--- 在每个有译文的叶子块尾插入译文。
--- 原文已是目标语言时译文只多出几个空白（Edge 会在中文句号后补空格），不算译文，不插。
---@param html string
---@param lookup table<string, string> 原文 → 译文
---@return string html
---@return integer count 插入的段数
function Markup.inject(html, lookup)
    local out, pos, count = {}, 1, 0
    for _idx, block in ipairs(Markup.blocks(html)) do
        local translated = lookup[block.text]
        if translated and translated:gsub("%s+", "") ~= block.text:gsub("%s+", "") then
            out[#out + 1] = html:sub(pos, block.close - 1)
            out[#out + 1] = '<br/><span class="' .. Markup.CLASS .. '" style="display:block">' .. Text.xmlEscape(translated) .. "</span>"
            pos = block.close
            count = count + 1
        end
    end
    out[#out + 1] = html:sub(pos)
    return table.concat(out), count
end

return Markup
