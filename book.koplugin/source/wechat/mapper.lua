--[[--
微信 wire → 领域对象

@module koplugin.book.source.wechat.mapper
--]]

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
        source_id = SOURCE_ID, stable_id = id,
        title = book.title or book.bookName or book.name,
        authors = book.authors or book.author,
        percent = Book.clampPercent(
            book.percent or book.progress or book.progressPercent or book.readProgress,
            finished
        ),
        category = book.category,
        series = book.series,
        cover = cover,
    }
    local intro = book.intro or book.description or book.summary
    if type(intro) == "string" and intro ~= "" then
        out.intro = intro
    end
    return out, cover
end

--- 书籍详情 wire → bookVersion（addBookmark 必填）。
---@param wire table|nil
---@return number|nil
function Mapper.bookVersion(wire)
    if type(wire) ~= "table" then
        return nil
    end
    local book = wire.book or wire.data or wire
    if type(book) ~= "table" then
        return nil
    end
    return tonumber(book.version or book.bookVersion or wire.version or wire.bookVersion)
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
    local cover = type(info.cover) == "string" and info.cover or nil
    local finished = info.finish == 1 or info.finish == true or info.finishStatus == "已完结"
    return {
        source_id = SOURCE_ID, stable_id = tostring(id),
        title = info.name or info.title,
        authors = info.authorName or info.author,
        percent = Book.clampPercent(0, finished),
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

--- 合并书架各列表并按 bookId 去重。
---@param into table[]
---@param seen table<string, boolean>
---@param rows table|nil
local function appendShelfRows(into, seen, rows)
    if type(rows) ~= "table" then
        return
    end
    for _, row in ipairs(rows) do
        local book = unwrapBookRow(row)
        if type(book) == "table" then
            local id = book.bookId or book.id or book.book_id
            if id ~= nil then
                id = tostring(id)
                if not seen[id] then
                    seen[id] = true
                    into[#into + 1] = row
                end
            end
        end
    end
end

--- 书架 wire → BookListResult。
---@param shelf table
---@param on_cover fun(stable_id: string, url: string)|nil
---@return BookListResult
function Mapper.shelfList(shelf, on_cover)
    local prog_map = Mapper.progressByBookId(shelf)
    local books = {}
    local list, seen = {}, {}
    appendShelfRows(list, seen, shelf.books)
    appendShelfRows(list, seen, shelf.recentBooks)
    appendShelfRows(list, seen, shelf.finishReadBooks)
    appendShelfRows(list, seen, shelf.data and shelf.data.books)
    for _, row in ipairs(list) do
        local b, cover = Mapper.book(row)
        if b then
            Mapper.applyProgress(b, prog_map[b.stable_id])
            if cover and on_cover then
                on_cover(b.stable_id, cover)
            end
            books[#books + 1] = b
        end
    end
    for _, album in ipairs(shelf.albums or {}) do
        local b, cover = Mapper.albumBook(album)
        if b then
            if cover and on_cover then
                on_cover(b.stable_id, cover)
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
                on_cover(b.stable_id, cover)
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
                tar = type(ch.tar) == "string" and ch.tar or nil,
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
            tar = type(ch.tar) == "string" and ch.tar ~= "" and ch.tar or nil,
        }
    end
    if #chapters == 0 then
        return nil, "empty"
    end
    return chapters
end

--- 章内偏移：微信 wire 为 0..10000，其它源可能已是 0..1。
---@param raw any
---@return number|nil
local function normalizeChapterOffset(raw)
    local n = tonumber(raw)
    if n == nil then
        return nil
    end
    if n > 1 then
        return ProgressPosition.clampFraction(n / 10000)
    end
    return ProgressPosition.clampFraction(n)
end

--- 进度 wire 解包：getProgress 进度在 book 子对象里。
---@param root table
---@return table
local function progressNode(root)
    local node = unwrapBookRow(root)
    if node and node ~= root then
        return node
    end
    if type(root.book) == "table" then
        return root.book
    end
    return root
end

--- 进度 wire → ProgressPosition。
---@param data table|nil
---@return ProgressPosition|nil, string|nil chapter_uid
function Mapper.progress(data)
    if type(data) ~= "table" then
        return nil
    end
    local root = data
    if type(data.data) == "table" then
        root = data.data
    end
    local node = progressNode(root)
    local finished = userFinished(node) or userFinished(root)
    local chapter_idx = tonumber(node.chapter_idx or node.chapterIdx)
    local chapter_fraction = normalizeChapterOffset(node.chapter_fraction or node.chapterOffset)
    local percent = tonumber(node.percent or node.progress or node.progressPercent or node.readingProgress)
    local fraction
    if percent and (percent > 0 or not chapter_idx) then
        fraction = ProgressPosition.clampFraction(
            Book.clampPercent(percent, finished) / 100
        )
    else
        fraction = 0
    end
    local chapter_uid = node.chapter_uid or node.chapterUid
    return {
        fraction = fraction,
        chapter_idx = chapter_idx,
        chapter_fraction = chapter_fraction,
        locator = node.locator,
    }, chapter_uid
end

--- 从 wire 行解出最近阅读时间戳。
---@param row table|nil
---@return number|nil
local function readUpdatedAt(row)
    if type(row) ~= "table" then
        return nil
    end
    local ts = tonumber(row.readUpdateTime or row.read_update_time or row.updateTime)
    if ts and ts > 0 then
        return ts
    end
    return nil
end

--- 书架条目上的真实阅读时间，供对应进度行补全时间戳。
---@param shelf table|nil
---@return table<string, number>
local function readTimesByBookId(shelf)
    if type(shelf) ~= "table" then return {} end
    local list, seen, out = {}, {}, {}
    appendShelfRows(list, seen, shelf.books)
    appendShelfRows(list, seen, shelf.recentBooks)
    appendShelfRows(list, seen, shelf.finishReadBooks)
    appendShelfRows(list, seen, shelf.data and shelf.data.books)
    for _, row in ipairs(list) do
        local book = unwrapBookRow(row)
        local id = type(book) == "table" and (book.bookId or book.id or book.book_id)
        local ts = readUpdatedAt(book)
        if id ~= nil and ts then out[tostring(id)] = ts end
    end
    for _, album in ipairs(shelf.albums or {}) do
        local info = album.albumInfo or album
        local extra = album.albumInfoExtra or {}
        local id = info and (info.albumId or album.albumId)
        local ts = tonumber(extra.lectureReadUpdateTime or info.updateTime)
        if id ~= nil and ts and ts > 0 then out[tostring(id)] = ts end
    end
    return out
end

--- 书架 wire 附带进度条目 → pending_progress 候选。
---@param shelf table|nil
---@return table[] rows { stable_id, fraction, chapter_idx?, chapter_fraction?, chapter_uid?, updated_at? }
function Mapper.shelfProgressRows(shelf)
    local prog_map = Mapper.progressByBookId(shelf)
    local read_times = readTimesByBookId(shelf)
    local rows = {}
    for id, p in pairs(prog_map) do
        local prog = tonumber(p.progress or p.readingProgress)
        local chapter_idx = tonumber(p.chapterIdx or p.chapter_idx)
        local chapter_fraction = normalizeChapterOffset(p.chapterOffset or p.chapter_offset)
        -- 两个进度字段都没有的条目不是进度，直接跳过
        if prog ~= nil or chapter_idx then
            rows[#rows + 1] = {
                stable_id = id,
                fraction = ProgressPosition.clampFraction((prog or 0) / 100),
                chapter_idx = chapter_idx,
                chapter_fraction = chapter_fraction,
                chapter_uid = p.chapterUid or p.chapter_uid,
                updated_at = readUpdatedAt(p) or read_times[id],
            }
        end
    end
    return rows
end

return Mapper
