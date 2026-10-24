--[[--
订阅文章排版：正文片段归一（标题层级、图片与图注、section）+ 文章样式表。

样式只管版式（间距、缩进、对齐、边框），不写字体与颜色：字体由月读字体设置给 CRE，夜间模式由 KOReader 反色，
字号用 em 跟随阅读器字号，与书源章节观感一致。

@module koplugin.book.features.subscribe.typography
--]]

local Text = require("utils.text")

local T = {}

T.CSS = table.concat({
    "body{margin:0 4%;line-height:1.75;text-align:justify;}",
    "h1{font-size:1.45em;line-height:1.35;margin:.6em 0 .3em;text-align:left;font-weight:bold;}",
    ".byline{font-size:.8em;margin:0 0 1.2em;text-align:left;}",
    "h2{font-size:1.25em;margin:1.2em 0 .5em;text-align:left;}",
    "h3{font-size:1.12em;margin:1em 0 .4em;text-align:left;}",
    "h4,h5,h6{font-size:1em;margin:1em 0 .3em;text-align:left;}",
    "p{margin:.5em 0;text-indent:0;}",
    "img{max-width:100%;}",
    "figure,.img{margin:1em 0;text-align:center;text-indent:0;}",
    "figcaption{font-size:.8em;margin-top:.3em;text-align:center;}",
    "blockquote{margin:.8em 0 .8em .4em;padding-left:.8em;border-left:.2em solid #888;}",
    "pre{font-family:monospace;font-size:.85em;white-space:pre-wrap;text-align:left;margin:.8em 0;",
    "padding:.5em;border:1px solid #aaa;}",
    "code{font-family:monospace;font-size:.9em;}pre code{font-size:1em;}",
    "ul,ol{margin:.5em 0;padding-left:1.6em;}li{margin:.2em 0;}",
    "table{border-collapse:collapse;margin:.8em 0;font-size:.9em;}td,th{border:1px solid #aaa;padding:.2em .4em;}",
    "hr{border:0;border-top:1px solid #aaa;margin:1.2em 0;}a{text-decoration:none;}",
})

--- 正文片段归一，返回带标题（和署名）的片段。
--- CRE 在 section / h1 前分页：section 换成 div，正文 h1 降成 h2（只留我们自己的标题是 h1）；
--- 段落里独占一行的图片包成居中块，紧跟的短斜体 / small 段落当图注。
---@param title string
---@param html string
---@param images boolean 是否保留图片
---@param byline string|nil
---@return string
function T.article(title, html, images, byline)
    if not images then
        html = html:gsub("<figure[^>]*>%s*<img%s[^>]*>%s*(.-)</figure>", "%1"):gsub("<img%s[^>]*>", "")
    end
    html = html:gsub("<(/?)section([%s>])", "<%1div%2"):gsub("<(/?)[hH]1([%s>])", "<%1h2%2")
    -- 二、三级标题编号：目录页的章内小节靠这个 id 跳转（T.headings 读回）
    local n = 0
    html = html:gsub("<[hH]([23])([^>]*)>", function(level, attrs)
        n = n + 1
        return "<h" .. level .. attrs:gsub('%sid%s*=%s*"[^"]*"', "") .. ' id="mh' .. n .. '">'
    end)
    -- 空段落与连续换行
    html = html:gsub("<p[^>]*>%s*</p>", ""):gsub("<p[^>]*>%s*<br%s*/?>%s*</p>", ""):gsub("(<br%s*/?>%s*)+(<br%s*/?>)", "%2")
    -- 只有一张图的段落 → 图块
    html = html:gsub("<p[^>]*>%s*(<img%s[^>]*>)%s*</p>", '<div class="img">%1</div>')
    local head = "<h1>" .. Text.xmlEscape(title) .. "</h1>"
    if byline and byline ~= "" then
        head = head .. '<p class="byline">' .. Text.xmlEscape(byline) .. "</p>"
    end
    return head .. Text.trim(html)
end

--- 读回 T.article 编了号的标题，做目录的章内小节：h1 / h2（正文 h1 已降成 h2）为第 2 级，h3 为第 3 级。
---@param html string
---@return BookChapterAnchor[]
function T.headings(html)
    local out = {}
    for level, id, inner in html:gmatch('<h([23])[^>]-id="(mh%d+)"[^>]*>(.-)</h%1>') do
        local title = Text.stripHtml(inner):gsub("%s+", " ")
        if title ~= "" then out[#out + 1] = { title = title, depth = tonumber(level), id = id } end
    end
    return out
end

--- 整篇文档（交 source.chapter 原样落盘）：<title> 是书名（订阅名），供阅读器认书。
---@param book_title string
---@param fragment string
---@return string
function T.document(book_title, fragment)
    return '<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8"/><title>' .. Text.xmlEscape(book_title)
        .. "</title><style>" .. T.CSS .. "</style></head><body>" .. fragment .. "</body></html>"
end

return T
