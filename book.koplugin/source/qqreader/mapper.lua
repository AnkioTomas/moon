--[[--
QQ阅读数据映射（纯函数）：详情 / 书架行 / 目录 → 领域对象。

封面不在详情里（cover 为空）。官方 getBookCover 默认尺寸 b，这里固定 jpg：
墨水屏不吃 webp。`cover/{bid%1000}/{bid}/b_{bid}.jpg`。

@module koplugin.book.source.qqreader.mapper
--]]

local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "qqreader"
local COVER = "https://wfqqreader-1252317822.image.myqcloud.com/cover/%d/%s/b_%s.jpg"

--- 搜索结果页（SSR HTML）→ Book[]：每条是 `<a title=书名 href=…/book-detail/书号>` 后跟简介段。
--- 作者名被站点截断成「xx...」，只在完整时才用。
---@param html string
---@return Book[]
function Mapper.searchHtml(html)
    local out, seen = {}, {}
    for title, id, rest in html:gmatch('<a title="([^"]*)" href="[^"]*/book%-detail/(%d+)"(.-)</a></div>') do
        if not seen[id] then
            seen[id] = true
            local intro = rest:match('<p class="intro"[^>]*>(.-)</p>')
            local author = rest:match('/book%-writer/%d+"[^>]*>(.-)</a>')
            author = author and Text.stripHtml(author)
            out[#out + 1] = {
                source_id = SOURCE_ID,
                stable_id = id,
                title = Text.xmlDecode(title),
                authors = author and not author:find("%.%.%.$") and author or nil,
                intro = intro and Text.stripHtml(intro),
                cover = Mapper.coverUrl(id),
            }
        end
    end
    return out
end

---@param value any
---@return boolean
local function on(value)
    return value == true or tonumber(value) == 1
end

--- 封面走阅文 CDN，书号即路径。实测 b_ 尺寸是 JPEG。
---@param book_id string|number
---@return string
function Mapper.coverUrl(book_id)
    local id = tostring(book_id)
    local n = tonumber(id)
    if not n then return "" end
    return COVER:format(n % 1000, id, id)
end

--- 详情 data → Book。分类用三级，没有再退二级。
---@param info table
---@return Book
function Mapper.book(info)
    local id = tostring(info.bid)
    local category = info.category3Name
    if type(category) ~= "string" or category == "" then category = info.category2Name end
    return {
        source_id = SOURCE_ID,
        stable_id = id,
        title = info.title,
        authors = info.author,
        category = category,
        intro = info.intro,
        cover = Mapper.coverUrl(id),
        meta = { words = tonumber(info.totalWords) },
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
        title = row.title,
        authors = row.author,
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

--- 详情或书架行里的阅读位置。0 就是没读过。
---@param row table|nil
---@return { uid: string }|nil
function Mapper.readChapter(row)
    local uid = type(row) == "table" and row.lastReadChapterId
    if uid == nil or tostring(uid) == "" or tonumber(uid) == 0 then return nil end
    return { uid = tostring(uid) }
end

--- 详情 inShelf：1 才在书架上。进度上传不在架上就失败，不要加回去。
---@param info table|nil
---@return boolean
function Mapper.onShelf(info)
    return type(info) == "table" and on(info.inShelf)
end

--- 目录数组 → 目录。free=0 是付费章，也进目录，打开时再看是否已授权。
---@param rows table|nil
---@return BookChapter[]
function Mapper.toc(rows)
    local toc = {}
    for _idx, row in ipairs(type(rows) == "table" and rows or {}) do
        if row.cid then
            toc[#toc + 1] = {
                idx = #toc + 1,
                uid = tostring(row.cid),
                title = row.chapterName,
                vip = tonumber(row.free) == 0,
            }
        end
    end
    return toc
end

--- 字体加密。抽到的章是明文；为真就失败，不要写解密。
---@param info table|nil
---@return boolean
function Mapper.encrypted(info)
    return type(info) == "table" and (on(info.encrypt) or on(info.fontEncrypt))
end

--- 未授权的付费章接口仍 code=0，并带约 200 字预览。不能看正文非空。
---@param info table|nil
---@return boolean
function Mapper.locked(info)
    return type(info) == "table" and on(info.chapterVipFlag) and not on(info.authStatus)
end

return Mapper
