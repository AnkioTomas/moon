--[[--
晋江文学城数据映射（纯函数）：App JSON 与手机网页 HTML → 领域对象。

@module koplugin.book.source.jjwxc.mapper
--]]

local Text = require("utils.text")
local Vip = require("source.jjwxc.vip")

local Mapper = {}

local SOURCE_ID = "jjwxc"

--- 带 ver 参数的封面链接服务端强制 gzip（Content-Encoding 与图片下载器不兼容，落盘变成无法识别的文件）；
--- 去掉 ver 就是同一张图的原始 PNG。
---@param url string|nil
---@return string|nil
local function cover(url)
    if type(url) ~= "string" or url == "" then return nil end
    return (url:gsub("&ver=[^&]*", ""))
end

--- novelbasicinfo → Book。简介是实体转义过的 HTML。
---@param info table
---@return Book
function Mapper.book(info)
    local words = tonumber((tostring(info.novelSize or ""):gsub(",", "")))
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(info.novelId),
        title = info.novelName,
        authors = info.authorName,
        category = info.novelClass,
        intro = info.novelIntro and Text.stripHtml(info.novelIntro),
        cover = cover(info.novelCover),
        meta = { words = words },
    }
end

--- 搜索 wire → Book[]（按 novelid / novelname 取，只留有书号的）。
---@param wire table
---@return Book[]
function Mapper.search(wire)
    local out = {}
    for _idx, item in ipairs(type(wire.items) == "table" and wire.items or {}) do
        if item.novelid then
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = tostring(item.novelid),
                title = item.novelname,
                authors = item.authorname,
                intro = item.novelintroshort and Text.stripHtml(item.novelintroshort),
                cover = cover(item.ebookurl),
            }
        end
    end
    return out
end

--- 手机榜单页 HTML → { title, books }[]：按「【xx排行】」分节，每节只有书名和书号（作者、封面等详情补）。
---@param html string
---@return { title: string, books: Book[] }[]
function Mapper.rankSections(html)
    local sections = {}
    for title, body in html:gmatch("【(.-)】(.-)</ul>") do
        local books = {}
        for id, name in body:gmatch('<a href="/book2/(%d+)"[^>]*>([^<]*)</a>') do
            books[#books + 1] = { source_id = SOURCE_ID, stable_id = id, title = Text.xmlDecode(name) }
        end
        if #books > 0 then sections[#sections + 1] = { title = title, books = books } end
    end
    return sections
end

--- 收藏页 HTML → { id, title, author }[]；找不到收藏列表（页面改版 / 不是收藏页）返回 nil。
--- 页面上的书名被截断，只作详情拉不到时的兜底。
---@param html string
---@return { id: string, title: string, author: string|nil }[]|nil
function Mapper.favRows(html)
    local list = html:match('<ul id="favul">(.-)</ul>')
    if not list then return nil end
    local rows = {}
    for item in list:gmatch("<li[^>]*>(.-)</li>") do
        local id, title = item:match('<a href="/book2/(%d+)"[^>]*>(.-)</a>')
        if id then
            rows[#rows + 1] = {
                id = id,
                title = Text.stripHtml(title),
                author = item:match('<a href="/wapauthor/%d+">(.-)</a>'),
            }
        end
    end
    return rows
end

--- App 书架 addData → 与网页收藏同形的 {id,title,author}；没有书号的丢弃。
---@param list table[]
---@return table[]
function Mapper.tokenFavRows(list)
    local rows = {}
    for _idx, item in ipairs(list) do
        local id = item.novelId or item.novelid
        if id then
            rows[#rows + 1] = {
                id = tostring(id),
                title = item.novelName or item.novelname,
                author = item.authorName or item.authorname,
            }
        end
    end
    return rows
end

--- 收藏行 → Book。本地已有同一本（local_book）沿用其完整元数据，没有就用刚拉到的详情，都没有才退回页面上截断的书名。
---@param rows table[] { id, title, author, info?: table, local_book?: Book }
---@return Book[]
function Mapper.shelfList(rows)
    local books = {}
    for _idx, row in ipairs(rows) do
        if row.info then
            books[#books + 1] = Mapper.book(row.info)
        elseif row.local_book then
            row.local_book.cover = cover(row.local_book.cover)
            books[#books + 1] = row.local_book
        else
            books[#books + 1] = { source_id = SOURCE_ID, stable_id = row.id, title = row.title, authors = row.author }
        end
    end
    return books
end

--- 目录缓存格式版本：2 起章节带 vip 标记。
Mapper.TOC_VERSION = 2

--- chapterList → 目录。卷标题（chaptertype 1）与审核中被锁的章不进目录；章号（uid）是接口里的 chapterid。
---@param wire table|nil
---@return BookChapter[]
function Mapper.toc(wire)
    local rows = wire and wire.chapterlist
    local toc = {}
    for _idx, row in ipairs(type(rows) == "table" and rows or {}) do
        if row.chaptertype ~= "1" and row.islock == "0" then
            toc[#toc + 1] = {
                idx = #toc + 1,
                uid = tostring(row.chapterid),
                title = row.chaptername,
                words = tonumber(row.chaptersize),
                vip = (tonumber(row.isvip) or 0) > 0 or nil,
            }
        end
    end
    if toc[1] then toc[1].toc_version = Mapper.TOC_VERSION end
    return toc
end

--- 取一条 CSS 规则里的 content 字符串（解 \' \" \\ 与 \XXXXXX 十六进制转义）；没有返回 nil。
---@param rule string
---@return string|nil
local function cssContent(rule)
    local _from, stop = rule:find("content%s*:%s*")
    if not stop then return nil end
    local quote = rule:sub(stop + 1, stop + 1)
    if quote ~= "'" and quote ~= '"' then return nil end
    local out, i = {}, stop + 2
    while i <= #rule do
        local c = rule:sub(i, i)
        if c == quote then return table.concat(out) end
        if c == "\\" then
            local hex, next_i = rule:match("^\\(%x%x?%x?%x?%x?%x?)%s?()", i)
            if hex then
                out[#out + 1] = Text.utf8char(tonumber(hex, 16) or 0)
                i = next_i
            else
                out[#out + 1] = rule:sub(i + 1, i + 1)
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil
end

--- VIP 页正文被切成 <span class="c_xxx">，段缝里的字不在解密片段里，挂在同页 <style> 的
--- .c_xxx:before/:after content 上，浏览器靠 CSS 拼出全文（issue #67）。收成 { 类名 -> { before, after } }。
---@param html string
---@return table
local function seamTexts(html)
    local seams = {}
    for style in html:gmatch("<style[^>]*>(.-)</style>") do
        for selectors, rule in style:gmatch("([^{}]+)%{([^{}]*)}") do
            local text = cssContent(rule)
            if text then
                for cls, kind in selectors:gmatch("%.(c_%w+)%s*::?%s*(%a+)") do
                    if kind == "before" or kind == "after" then
                        local seam = seams[cls] or {}
                        seam[kind] = text
                        seams[cls] = seam
                    end
                end
            end
        end
    end
    return seams
end

--- 把段缝拼回片段：span 开标签换成该类的 before、配对的 </span> 换成 after，之后再走原有剥标签。
--- 片段里 span 不嵌套，按出现顺序配对。
---@param body string
---@param seams table
---@return string
local function spliceSeams(body, seams)
    local opens, closed = {}, 0
    body = body:gsub("<[Ss][Pp][Aa][Nn][^>]*>", function(tag)
        local cls = tag:match("class%s*=%s*['\"](c_%w+)['\"]")
        opens[#opens + 1] = cls
        local seam = cls and seams[cls]
        return seam and seam.before or ""
    end)
    return (body:gsub("</[Ss][Pp][Aa][Nn]%s*>", function()
        closed = closed + 1
        local seam = opens[closed] and seams[opens[closed]]
        return seam and seam.after or ""
    end))
end

--- 章节网页 HTML → 正文纯文本；不是正文页（未购买的提示页等）返回 nil。
---@param html string
---@return string|nil
---@return string|nil 加密页解不开时的失败阶段
function Mapper.webContent(html)
    local body, why
    if html:find('id="contentvars"', 1, true) then
        body, why = Vip.content(html)
    else
        body = html:match('<ul class="content_ul">%s*<li[^>]*>(.-)</li>')
    end
    if not body then return nil, why end
    local seams = seamTexts(html)
    if next(seams) then body = spliceSeams(body, seams) end
    body = body:gsub("<script.-</script>", ""):gsub("&zwnj;", ""):gsub("&#([xX]%x+);?", "&#%1;")
    local text = Text.xmlDecode((body:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("<[^>]*>", "")))
    return Text.trim(text) ~= "" and text or nil
end

return Mapper
