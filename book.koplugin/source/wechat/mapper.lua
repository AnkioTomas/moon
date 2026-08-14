--[[--
微信 wire → 领域对象

@module koplugin.book.source.wechat.mapper
--]]

local BookRef = require("types.book").BookRef
local Book = require("types.book").Book
local ProgressPosition = require("types.book_progress")
local BookListResult = require("types.book_list")

local Mapper = {}

local SOURCE_ID = "wechat"

--- 从嵌套 book/bookInfo 行解出书籍对象。
---@param row table|nil
---@return table|nil
local function unwrapBookRow(row)
    if type(row) ~= "table" then
        return nil
    end
    if type(row.book) == "table" and (row.book.bookId or row.book.title or row.book.id) then
        local inner = row.book
        if row.progress ~= nil and inner.progress == nil then
            inner = setmetatable({ progress = row.progress }, { __index = inner })
        end
        if row.finishReading ~= nil and inner.finishReading == nil then
            inner = setmetatable({
                progress = inner.progress,
                finishReading = row.finishReading,
            }, { __index = inner })
        end
        return inner
    end
    if type(row.bookInfo) == "table" and (row.bookInfo.bookId or row.bookInfo.title) then
        return row.bookInfo
    end
    return row
end

--- 判断用户是否已读完（勿与作品完结 finished 混淆）。
---@param row table|nil
---@return boolean
local function userFinished(row)
    if type(row) ~= "table" then
        return false
    end
    if row.finishReading == 1 or row.finishReading == true then
        return true
    end
    if row.isFinishReading == 1 or row.isFinishReading == true then
        return true
    end
    if row.hasReadTag == true or row.hasReadTag == 1 then
        return true
    end
    -- 注意：微信作品完结 finished=1 不是用户读完
    return false
end

--- 微信书籍行 → Book（及封面 URL）。
---@param row table|nil
---@return Book|nil, string|nil cover_url
function Mapper.book(row)
    local book = unwrapBookRow(row)
    if type(book) ~= "table" then
        return nil
    end
    local id = book.id or book.bookId or book.book_id
    if id == nil then
        return nil
    end
    id = tostring(id)
    if id == "" then
        return nil
    end
    local finished = userFinished(book)
    local cover = type(book.cover) == "string" and book.cover or nil
    local out = {
        ref = BookRef.new(SOURCE_ID, id),
        title = book.title or book.bookName or book.name,
        authors = book.authors or book.author,
        percent = Book.clampPercent(
            book.percent or book.progress or book.progressPercent or book.readProgress,
            finished
        ),
        category = book.category,
        favorite = book.favorite or (book.isTop == 1) or nil,
        series = book.series,
        cover = cover,
    }
    local intro = book.intro or book.description or book.summary
    if type(intro) == "string" and intro ~= "" then
        out.intro = intro
    end
    return out, cover
end

--- 微信专辑 → Book（及封面 URL）。
---@param album table
---@return Book|nil, string|nil
function Mapper.albumBook(album)
    if type(album) ~= "table" then
        return nil
    end
    local info = album.albumInfo or album
    if type(info) ~= "table" then
        return nil
    end
    local id = info.albumId or album.albumId
    if not id then
        return nil
    end
    local extra = album.albumInfoExtra
    local cover = type(info.cover) == "string" and info.cover or nil
    local finished = info.finish == 1 or info.finish == true or info.finishStatus == "已完结"
    return {
        ref = BookRef.new(SOURCE_ID, tostring(id)),
        title = info.name or info.title,
        authors = info.authorName or info.author,
        percent = Book.clampPercent(0, finished),
        favorite = type(extra) == "table" and extra.isTop == 1 or nil,
        cover = cover,
    }, cover
end

--- 把书架进度写回 Book。
---@param book Book
---@param p table|nil
---@return Book
function Mapper.applyProgress(book, p)
    if type(book) ~= "table" or type(p) ~= "table" then
        return book
    end
    local prog = tonumber(p.progress)
    if prog then
        book.percent = Book.clampPercent(prog, false)
    end
    if p.finishReading == 1 or p.finishReading == true then
        book.percent = 100
    end
    return book
end

--- 从书架提取 bookId→进度表。
---@param shelf table|nil
---@return table<string, table>
function Mapper.progressByBookId(shelf)
    local map = {}
    if type(shelf) ~= "table" or type(shelf.bookProgress) ~= "table" then
        return map
    end
    for _, p in ipairs(shelf.bookProgress) do
        local id = p and p.bookId
        if id ~= nil then
            map[tostring(id)] = p
        end
    end
    return map
end

--- 书架 wire → BookListResult。
---@param shelf table
---@param on_cover fun(stable_id: string, url: string)|nil
---@return BookListResult
function Mapper.shelfList(shelf, on_cover)
    local prog_map = Mapper.progressByBookId(shelf)
    local books = {}
    local list = shelf.books
        or shelf.recentBooks
        or (shelf.data and shelf.data.books)
        or {}
    if #list == 0 and type(shelf.finishReadBooks) == "table" then
        for _, row in ipairs(shelf.finishReadBooks) do
            list[#list + 1] = row
        end
    end
    for _, row in ipairs(list) do
        local b, cover = Mapper.book(row)
        if b then
            Mapper.applyProgress(b, prog_map[b.ref.stable_id])
            if cover and on_cover then
                on_cover(b.ref.stable_id, cover)
            end
            books[#books + 1] = b
        end
    end
    for _, album in ipairs(shelf.albums or {}) do
        local b, cover = Mapper.albumBook(album)
        if b then
            if cover and on_cover then
                on_cover(b.ref.stable_id, cover)
            end
            books[#books + 1] = b
        end
    end
    return BookListResult.new(books)
end

--- 最近阅读 wire → BookListResult。
---@param data table
---@param shelf table|nil
---@param on_cover fun(stable_id: string, url: string)|nil
---@return BookListResult
function Mapper.recentList(data, shelf, on_cover)
    local prog_map = Mapper.progressByBookId(shelf)
    local books = {}
    for _, item in ipairs(data.items or {}) do
        local b, cover = Mapper.book(item)
        if b then
            Mapper.applyProgress(b, prog_map[b.ref.stable_id])
            if cover and on_cover then
                on_cover(b.ref.stable_id, cover)
            end
            books[#books + 1] = b
        end
    end
    return BookListResult.new(books)
end

--- 搜索结果 wire → BookListResult。
---@param data table
---@param on_cover fun(stable_id: string, url: string)|nil
---@return BookListResult
function Mapper.searchList(data, on_cover)
    local books = {}
    local list = data.books or data.list or data.parts
        or (data.data and (data.data.books or data.data.list))
        or {}
    if #list == 0 and type(data.parts) == "table" then
        for _, part in ipairs(data.parts) do
            if type(part) == "table" and type(part.cards) == "table" then
                for _, card in ipairs(part.cards) do
                    list[#list + 1] = card
                end
            end
        end
    end
    if #list == 0 and type(data.results) == "table" then
        for _, group in ipairs(data.results) do
            if type(group) == "table" and type(group.books) == "table" then
                for _, row in ipairs(group.books) do
                    list[#list + 1] = (type(row) == "table" and (row.bookInfo or row.book or row)) or row
                end
            end
        end
    end
    for _, row in ipairs(list) do
        local b, cover = Mapper.book(type(row) == "table" and (row.book or row) or row)
        if b then
            if cover and on_cover then
                on_cover(b.ref.stable_id, cover)
            end
            books[#books + 1] = b
        end
    end
    return BookListResult.new(books)
end

--- 章节列表 wire → BookChapter[]。
---@param data table
---@param bookId string
---@return BookChapter[]|nil, string|nil
function Mapper.chapters(data, bookId)
    local records = data.data or data
    if type(records) ~= "table" then
        return nil, "empty"
    end
    if records.bookId or records.updated then
        records = { records }
    end
    local entry
    for _, rec in ipairs(records) do
        if tostring(rec.bookId or "") == bookId or not entry then
            entry = rec
            if tostring(rec.bookId or "") == bookId then
                break
            end
        end
    end
    if type(entry) ~= "table" then
        return nil, "empty"
    end
    local chapters_raw = entry.updated or entry.chapterInfos or entry.chapters or {}
    local staged = {}
    for _, ch in ipairs(chapters_raw) do
        local wc = tonumber(ch.wordCount or 0) or 0
        local title = tostring(ch.title or "")
        if wc > 0 and title ~= "封面" then
            staged[#staged + 1] = {
                source_idx = ch.chapterIdx or ch.idx,
                uid = ch.chapterUid or ch.uid,
                title = title,
            }
        end
    end
    table.sort(staged, function(a, b)
        return (tonumber(a.source_idx) or 0) < (tonumber(b.source_idx) or 0)
    end)
    local chapters = {}
    for i, ch in ipairs(staged) do
        local title = ch.title
        if not title or title == "" then
            title = "第" .. tostring(ch.source_idx or i) .. "章"
        end
        chapters[#chapters + 1] = {
            idx = i,
            source_idx = ch.source_idx ~= nil and tostring(ch.source_idx) or nil,
            uid = ch.uid ~= nil and tostring(ch.uid) or nil,
            title = title,
        }
    end
    if #chapters == 0 then
        return nil, "empty"
    end
    return chapters
end

--- 进度 wire → ProgressPosition。
---@param data table|nil
---@return ProgressPosition|nil, string|nil chapter_uid
function Mapper.progress(data)
    if type(data) ~= "table" then
        return nil
    end
    local node = data
    if type(data.data) == "table" then
        node = data.data
    end
    local finished = userFinished(node) or userFinished(data)
    local percent = Book.clampPercent(
        node.percent or node.progress or node.progressPercent or node.readingProgress,
        finished
    )
    local chapter_uid = node.chapter_uid or node.chapterUid
    return {
        fraction = ProgressPosition.clampFraction(percent / 100),
        chapter_idx = tonumber(node.chapter_idx or node.chapterIdx),
        chapter_fraction = tonumber(node.chapter_fraction or node.chapterOffset),
        locator = node.locator,
    }, chapter_uid
end

return Mapper
