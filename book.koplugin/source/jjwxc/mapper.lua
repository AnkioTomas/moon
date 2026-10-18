--[[--
晋江文学城数据映射（纯函数）：App JSON 与手机网页 HTML → 领域对象。

@module koplugin.book.source.jjwxc.mapper
--]]

local Text = require("utils.text")

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
            }
        end
    end
    return toc
end

--- 章节网页 HTML → 正文纯文本；不是正文页（未购买的提示页等）返回 nil。
---@param html string
---@return string|nil
function Mapper.webContent(html)
    local body = html:match('<ul class="content_ul">%s*<li[^>]*>(.-)</li>')
    if not body then return nil end
    local text = Text.xmlDecode((body:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("<[^>]*>", "")))
    return Text.trim(text) ~= "" and text or nil
end

return Mapper
