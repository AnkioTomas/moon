--[[--
微信 wire → 领域对象

@module koplugin.book.source.wechat.mapper
--]]

local Progress = require("book.progress")
local Catalog = require("book.catalog")
local Text = require("utils.text")

local Mapper = {}

local SOURCE_ID = "wechat"

--- 从嵌套 book/bookInfo 行解出书籍对象。
---@param row table|nil
---@return table|nil
local function unwrapBookRow(row)
    if type(row) ~= "table" then
        return nil
    end
    local inner = row.book
    if type(inner) == "table" and (inner.bookId or inner.title or inner.id) then
        -- 进度与已读标记可能挂在外层，内层没有时补上。
        local patch = {}
        if inner.progress == nil then patch.progress = row.progress end
        if inner.finishReading == nil then patch.finishReading = row.finishReading end
        return next(patch) and setmetatable(patch, { __index = inner }) or inner
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
    local cover = type(book.cover) == "string" and book.cover ~= "" and book.cover or nil
    -- 搜索 / 榜单给的是 s_ 缩略图（70x100），同路径 t7_ 是 285x406
    cover = cover and cover:gsub("/s_([^/]+)$", "/t7_%1")
    local out = {
        source_id = SOURCE_ID, stable_id = id,
        title = book.title or book.bookName or book.name,
        authors = book.authors or book.author,
        percent = Progress.clampPercent(
            book.percent or book.progress or book.progressPercent or book.readProgress,
            finished
        ),
        category = book.category,
        series = book.series,
        cover = cover,
        read_at = tonumber(book.readUpdateTime),
        -- publishTime 形如 "2022-01-01 00:00:00"；newRating 是千分制推荐值（955 = 95.5%）。
        -- 规范化（只留年月、10 分制一位小数）在 BookDB 入库时做。
        meta = {
            publisher = book.publisher,
            published = book.publishTime,
            isbn = book.isbn,
            language = book.language,
            words = book.totalWords,
            rating = { score = (tonumber(book.newRating) or 0) / 100, by = "weread" },
        },
    }
    local intro = book.intro or book.description or book.summary
    if type(intro) == "string" and intro ~= "" then
        out.intro = Text.stripHtml(intro)
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
    local cover = type(info.cover) == "string" and info.cover ~= "" and info.cover or nil
    local finished = info.finish == 1 or info.finish == true or info.finishStatus == "已完结"
    return {
        source_id = SOURCE_ID, stable_id = tostring(id),
        title = info.name or info.title,
        authors = info.authorName or info.author,
        percent = Progress.clampPercent(0, finished),
        cover = cover,
    }, cover
end

--- 把书架进度写回 Book。
---@param book Book
---@param p table|nil
---@return Book
function Mapper.applyProgress(book, p)
    if type(p) ~= "table" then
        return book
    end
    local prog = tonumber(p.progress)
    if prog then
        book.percent = Progress.clampPercent(prog, false)
    end
    if p.finishReading == 1 or p.finishReading == true then
        book.percent = 100
    end
    -- bookProgress.updateTime：任一设备最近一次读这本书的时间（秒）
    local at = tonumber(p.updateTime)
    if at and at > (tonumber(book.read_at) or 0) then book.read_at = at end
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
    for _idx, p in ipairs(shelf.bookProgress) do
        local id = p and p.bookId
        if id ~= nil then
            map[tostring(id)] = p
        end
    end
    return map
end

--- 书架 archive（用户自建分组）→ bookId→分组名；一本书在多个分组时取第一个。
---@param shelf table|nil
---@return table<string, string>
function Mapper.groupByBookId(shelf)
    local map = {}
    for _idx, archive in ipairs(type(shelf) == "table" and type(shelf.archive) == "table" and shelf.archive or {}) do
        if type(archive) == "table" and type(archive.name) == "string" and type(archive.bookIds) == "table" then
            for _i, id in ipairs(archive.bookIds) do map[tostring(id)] = map[tostring(id)] or archive.name end
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
    for _idx, row in ipairs(rows) do
        local book = unwrapBookRow(row)
        if type(book) == "table" then
            local id = book.bookId or book.id or book.book_id
            -- 公众号只走订阅导入（features.subscribe 直接读书架 wire），不进书库。
            if id ~= nil and tostring(id):sub(1, 7) ~= "MP_WXS_" then
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
    local groups = Mapper.groupByBookId(shelf)
    local books = {}
    local list, seen = {}, {}
    appendShelfRows(list, seen, shelf.books)
    appendShelfRows(list, seen, shelf.recentBooks)
    appendShelfRows(list, seen, shelf.finishReadBooks)
    appendShelfRows(list, seen, shelf.data and shelf.data.books)
    for _idx, row in ipairs(list) do
        local b, cover = Mapper.book(row)
        if b then
            Mapper.applyProgress(b, prog_map[b.stable_id])
            b.category = groups[b.stable_id] or b.category
            if cover and on_cover then
                on_cover(b.stable_id, cover)
            end
            books[#books + 1] = b
        end
    end
    for _idx, album in ipairs(shelf.albums or {}) do
        local b, cover = Mapper.albumBook(album)
        if b then
            if cover and on_cover then
                on_cover(b.stable_id, cover)
            end
            books[#books + 1] = b
        end
    end
    return Catalog.listResult(books)
end

--- 章名已以「第…章」开头（序号部分不含空白、不超过 8 个汉字）。
---@param title string
---@return boolean
local function numbered(title)
    local head = title:match("^第(.-)章")
    return head ~= nil and #head <= 24 and not head:find("%s")
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
    for _idx, rec in ipairs(records) do
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
    local chapters = {}
    for _idx, ch in ipairs(chapters_raw) do
        local wc = tonumber(ch.wordCount or 0) or 0
        local title = tostring(ch.title or "")
        if wc > 0 and title ~= "封面" then
            local depth = math.max(1, math.floor(tonumber(ch.level) or 1))
            local anchors = {}
            for _idx, anchor in ipairs(ch.anchors or {}) do
                local anchor_title = tostring(anchor.title or "")
                if anchor_title ~= "" then
                    anchors[#anchors + 1] = {
                        title = anchor_title,
                        depth = math.max(1, math.floor(tonumber(anchor.level) or (depth + 1))),
                    }
                end
            end
            local source_idx = ch.chapterIdx or ch.idx
            local uid = ch.chapterUid or ch.uid
            chapters[#chapters + 1] = {
                depth = depth,
                anchors = #anchors > 0 and anchors or nil,
                source_idx = source_idx ~= nil and tostring(source_idx) or nil,
                uid = uid ~= nil and tostring(uid) or nil,
                title = title,
                words = wc,
                tar = type(ch.tar) == "string" and ch.tar ~= "" and ch.tar or nil,
            }
        end
    end
    table.sort(chapters, function(a, b)
        return (tonumber(a.source_idx) or 0) < (tonumber(b.source_idx) or 0)
    end)
    -- 网文（format=txt）的章名不带序号，微信客户端按 chapterIdx 拼「第 N 章」；出版书原样。
    local txt = type(entry.book) == "table" and entry.book.format == "txt"
    for i, ch in ipairs(chapters) do
        ch.idx = i
        local number = "第" .. (ch.source_idx or tostring(i)) .. "章"
        if ch.title == "" then
            ch.title = number
        elseif txt and not numbered(ch.title) then
            ch.title = number .. " " .. ch.title
        end
    end
    if #chapters == 0 then
        return nil, "empty"
    end
    chapters[1].toc_version = require("source.wechat.toc").FORMAT_VERSION
    return chapters
end

---@class WechatSearchBook
---@field book_id string
---@field title string
---@field author string
---@field publisher string

--- 搜索 wire → 书目（只留带 bookId 的书，公众号等其它条目没有 bookInfo）。
---@param data table
---@return WechatSearchBook[]
function Mapper.searchBooks(data)
    local out = {}
    for _idx, entry in ipairs(data.books or {}) do
        local info = entry.bookInfo
        if type(info) == "table" and info.bookId then
            out[#out + 1] = {
                book_id = tostring(info.bookId),
                title = info.title or "",
                author = info.author or "",
                publisher = info.publisher or "",
            }
        end
    end
    return out
end

--- 搜索 wire → Book[]（书城用；公众号等没有 bookInfo 的条目被 Mapper.book 滤掉）。
---@param data table
---@return Book[]
function Mapper.searchList(data)
    local out = {}
    for _idx, entry in ipairs(data.books or {}) do
        if type(entry.bookInfo) == "table" then
            local book = Mapper.book(entry)
            if book then out[#out + 1] = book end
        end
    end
    return out
end

--- 榜单 / 分类目录 wire → 精简树，原始 JSON 带大量封面字段，不留。
--- 榜单是 ranklist=1 的项；分类是其余带子分类的项（讲书榜、有声榜等无子分类的不要）。
---@param data table
---@return { rankings: { id: string, title: string }[], categories: { id: string, title: string, subs: { id: string, title: string }[] }[] }
function Mapper.storeTree(data)
    local tree = { rankings = {}, categories = {} }
    for _idx, group in ipairs(data.data or {}) do
        for _idx2, row in ipairs(group.categories or {}) do
            local id = row.CategoryId and tostring(row.CategoryId)
            if id and type(row.title) == "string" then
                if row.ranklist == 1 then
                    tree.rankings[#tree.rankings + 1] = { id = id, title = row.title }
                elseif #(row.sublist or {}) > 0 then
                    local subs = {}
                    for _idx3, sub in ipairs(row.sublist) do
                        subs[#subs + 1] = { id = tostring(sub.CategoryId), title = sub.title }
                    end
                    tree.categories[#tree.categories + 1] = { id = id, title = row.title, subs = subs }
                end
            end
        end
    end
    return tree
end

--- 进度 wire → ProgressPosition（getProgress 的进度在 book 子对象里）。
---@param data table
---@return ProgressPosition, string|nil chapter_uid
function Mapper.progress(data)
    local root = type(data.data) == "table" and data.data or data
    local node = unwrapBookRow(root)
    if node == root and type(root.book) == "table" then node = root.book end
    local finished = userFinished(node) or userFinished(root)
    local chapter_idx = tonumber(node.chapter_idx or node.chapterIdx)
    local offset = tonumber(node.chapterOffset)
    local chapter_fraction = tonumber(node.chapter_fraction)
    if chapter_fraction then chapter_fraction = Progress.clampFraction(chapter_fraction) end
    local percent = tonumber(node.percent or node.progress or node.progressPercent or node.readingProgress)
    local fraction = 0
    if percent and (percent > 0 or not chapter_idx) then
        fraction = Progress.clampFraction(Progress.clampPercent(percent, finished) / 100)
    end
    local chapter_uid = node.chapter_uid or node.chapterUid
    return {
        fraction = fraction,
        chapter_idx = chapter_idx,
        chapter_fraction = chapter_fraction,
        locator = node.locator,
        extra = { chapter_offset = offset, summary = node.summary, book_version = node.bookVersion },
    }, chapter_uid
end

return Mapper
