--[[--
起点中文网数据映射（纯函数）：手机网页 pageContext JSON / 书架行 → 领域对象。

@module koplugin.book.source.qidian.mapper
--]]

local JSON = require("json")
local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "qidian"
local COVER = "https://bookcover.yuewen.com/qdbimg/349573/%s/180"

--- 封面走阅文 CDN，书号即路径。实测是 JPEG，不强制 gzip。
---@param book_id string|number
---@return string
function Mapper.coverUrl(book_id)
    return COVER:format(tostring(book_id))
end

--- 手机网页 SSR 的 pageContext → pageData；不是起点页面返回 nil。
---@param html string
---@return table|nil
function Mapper.pageData(html)
    local raw = type(html) == "string"
        and html:match('id="vite%-plugin%-ssr_pageContext" type="application/json">(.-)</script>')
    if not raw then return nil end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil end
    local props = (wire.pageContext or wire).pageProps
    local data = props and props.pageData
    return type(data) == "table" and data or nil
end

--- 详情页 bookInfo → Book。
---@param info table
---@return Book
function Mapper.book(info)
    local id = tostring(info.bookId)
    return {
        source_id = SOURCE_ID,
        stable_id = id,
        title = info.bookName,
        authors = info.authorName,
        category = info.chanName,
        intro = info.desc and Text.stripHtml(info.desc),
        cover = Mapper.coverUrl(id),
        meta = { words = tonumber(info.wordsCnt) },
    }
end

--- 书架行 → Book。没有简介，封面按书号拼。
---@param row table
---@return Book
function Mapper.shelfBook(row)
    local id = tostring(row.bid)
    return {
        source_id = SOURCE_ID,
        stable_id = id,
        title = row.bName,
        authors = row.bAuth,
        category = row.cateName,
        cover = Mapper.coverUrl(id),
    }
end

--- 书架行 → Book。有详情用详情，否则沿用本地完整行，都没有才退回书架行。
---@param rows table[]
---@return Book[]
function Mapper.shelfList(rows)
    local books = {}
    for _idx, row in ipairs(rows) do
        if row.info then
            books[#books + 1] = Mapper.book(row.info)
        elseif row.local_book then
            local book = row.local_book
            if type(book.cover) ~= "string" or book.cover == "" then
                book.cover = Mapper.coverUrl(row.bid or book.stable_id)
            end
            books[#books + 1] = book
        elseif row.bid then
            books[#books + 1] = Mapper.shelfBook(row)
        end
    end
    return books
end

--- 目录页 vs[].cs[] → 目录。卷名不是章；VIP 章（sS=0）也进目录，打开时再看是否已购买。
---@param data table|nil
---@return BookChapter[]
function Mapper.toc(data)
    local volumes = data and data.vs
    local toc = {}
    for _idx, volume in ipairs(type(volumes) == "table" and volumes or {}) do
        for _ch, row in ipairs(type(volume.cs) == "table" and volume.cs or {}) do
            if row.id then
                toc[#toc + 1] = {
                    idx = #toc + 1,
                    uid = tostring(row.id),
                    title = row.cN,
                    words = tonumber(row.cnt),
                }
            end
        end
    end
    return toc
end

--- 未购买的 VIP 只有预览。免费章 isBuy 也是 0，锁章只看 vipStatus。
---@param info table|nil
---@return boolean
function Mapper.locked(info)
    return type(info) == "table" and tonumber(info.vipStatus) == 1 and tonumber(info.isBuy) ~= 1
end

--- 章节 HTML → 纯文本。起点用 <p> 分段，且不保证闭合。
---@param html string|nil
---@return string|nil
function Mapper.chapterText(html)
    if type(html) ~= "string" or html == "" then return nil end
    local text = Text.xmlDecode((html
        :gsub("<[Pp][^>]*>", "\n")
        :gsub("</[Pp]>", "\n")
        :gsub("<[Bb][Rr]%s*/?>", "\n")
        :gsub("<[^>]*>", "")))
    return Text.trim(text) ~= "" and text or nil
end

return Mapper
