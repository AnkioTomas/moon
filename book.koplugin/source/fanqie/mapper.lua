--[[--
番茄小说官方 wire → 月读领域对象。

@module koplugin.book.source.fanqie.mapper
--]]

local Book = require("types.book").Book
local BookListResult = require("types.book_list")
local ProgressPosition = require("types.book_progress")
local Text = require("utils.text")

local Mapper = {}
local SOURCE_ID = "fanqie"

---@param value any
---@return string|nil
local function stringValue(value)
    if type(value) == "string" then return value ~= "" and value or nil end
    if type(value) == "number" then return tostring(value) end
end

---@param value any
---@return string|nil
local function coverUrl(value)
    local url = stringValue(value)
    if not url then return nil end
    if url:sub(1, 2) == "//" then url = "https:" .. url end
    if url:match("^https?://") then return url end
    return "https://p3-reading-sign.fqnovelpic.com/" .. url:gsub("^/+", "")
end

---@param row table|nil
---@param fallback_id string|nil
---@return Book|nil, string|nil
function Mapper.book(row, fallback_id)
    if type(row) ~= "table" then return nil end
    row = type(row.ebook) == "table" and row.ebook or row
    local id = row.book_id or row.bookId or row.media_id or row.mediaId or row.id or fallback_id
    if id == nil or tostring(id) == "" then return nil end
    local read_progress = tonumber(row.read_progress)
    local percent
    if read_progress then
        percent = read_progress > 1 and read_progress / 10000 * 100 or read_progress * 100
    elseif row.real_chapter_order and row.serial_count and tonumber(row.serial_count) > 0 then
        percent = tonumber(row.real_chapter_order) * 100 / tonumber(row.serial_count)
    else
        percent = row.percent or row.progress
    end
    local status = tonumber(row.creation_status or row.creationStatus or row.status)
    local finished = status == 1 or row.finished == true
    local category = row.category or row.category_name or row.categoryName
    if type(category) == "table" then
        local values = {}
        for _, item in ipairs(category) do
            local value = stringValue(item)
                or (type(item) == "table" and stringValue(item.name))
            if value then values[#values + 1] = value end
        end
        category = table.concat(values, ", ")
    end
    local cover = coverUrl(row.thumb_url or row.thumbUrl or row.cover_url
        or row.coverUrl or row.cover or row.detail_page_thumb_url)
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(id),
        title = stringValue(row.book_name or row.bookName or row.title or row.name),
        authors = stringValue(row.author_name or row.authorName or row.author or row.authors),
        percent = Book.clampPercent(percent, finished),
        category = stringValue(category),
        intro = stringValue(row.description or row.desc or row.abstract or row.intro or row.introduce),
        cover = cover,
        in_library = row.in_library,
    }, cover
end

---@param wire table
---@return table[]
local function rows(wire)
    local data = type(wire.data) == "table" and wire.data or wire
    local list = data.detail_list or data.detailList or data.books or data.items
    if type(list) ~= "table" then list = data end
    return type(list) == "table" and list or {}
end

---@param wire table
---@param on_cover fun(id: string, url: string)|nil
---@return BookListResult
function Mapper.shelfList(wire, on_cover)
    local books = {}
    for _, row in ipairs(rows(wire)) do
        local book, cover = Mapper.book(row)
        if book then
            book.in_library = true
            if cover and on_cover then on_cover(book.stable_id, cover) end
            books[#books + 1] = book
        end
    end
    return BookListResult.new(books, #books)
end

---@param wire table
---@return Book|nil, string|nil
function Mapper.detail(wire, fallback_id)
    local list = rows(wire)
    return Mapper.book(list[1], fallback_id)
end

---@param wire table
---@return BookChapter[]|nil
function Mapper.chapters(wire)
    local data = type(wire.data) == "table" and wire.data or wire
    local source = data.chapterList or data.chapter_list or data.chapters
        or data.item_list or data.items
    local chapters = {}
    local function append(value, depth)
        if type(value) ~= "table" then return end
        for _, row in ipairs(value) do
            if type(row) == "table" then
                local nested = row.chapters or row.chapterList or row.chapter_list
                if nested then
                    append(nested, depth + 1)
                else
                    local uid = row.item_id or row.itemId or row.chapter_id or row.chapterId
                        or row.catalog_id or row.catalogId or row.id
                    if uid ~= nil and tostring(uid) ~= "" then
                        chapters[#chapters + 1] = {
                            idx = #chapters + 1,
                            source_idx = row.chapter_index or row.chapter_idx or row.index
                                or row.serial_number,
                            uid = tostring(uid),
                            title = stringValue(row.title or row.chapter_title
                                or row.chapterTitle or row.name or row.chapter_name)
                                or ("第" .. (#chapters + 1) .. "章"),
                            depth = math.max(1, math.floor(tonumber(row.level) or depth or 1)),
                        }
                    end
                end
            end
        end
    end
    append(source, 1)
    return #chapters > 0 and chapters or nil
end

---@param wire table
---@return ProgressPosition|nil, string|nil
function Mapper.progress(wire)
    local data = type(wire.data) == "table" and wire.data or {}
    local row = data[1]
    if type(row) ~= "table" then row = data.progress or data end
    if type(row) ~= "table" then return nil end
    local raw = tonumber(row.read_progress)
    local fraction
    if raw ~= nil then
        fraction = raw > 1 and raw / 10000 or raw
    else
        fraction = ProgressPosition.clampFraction(row.progress or row.percent)
    end
    local uid = row.item_id or row.itemId or row.chapter_id or row.chapterId
    local position = {
        fraction = ProgressPosition.clampFraction(fraction),
        chapter_fraction = ProgressPosition.clampFraction(row.chapter_progress or row.chapterProgress),
        updated_at = tonumber(row.read_timestamp or row.updated_at or row.update_time),
    }
    local index = tonumber(row.index or row.chapter_index or row.chapter_idx)
    if uid ~= nil then uid = tostring(uid) end
    if not uid and not index and position.fraction == 0 then return nil end
    return position, uid, index
end

---@param wire table
---@param fallback_title string|nil
---@return ChapterContentPayload|nil
function Mapper.content(wire, fallback_title)
    local data = type(wire.data) == "table" and wire.data or wire
    local raw = data.content or data.text or data.body or data.html
    if type(raw) == "table" then
        local parts = {}
        for _, item in ipairs(raw) do
            if type(item) == "table" then item = item.content or item.text or item.html end
            if type(item) == "string" and item ~= "" then parts[#parts + 1] = item end
        end
        raw = table.concat(parts, "\n")
    end
    if type(raw) ~= "string" or Text.trim(raw) == "" then return nil end
    local title = stringValue(data.title or data.chapter_title or data.chapterTitle) or fallback_title
    if Text.looksLikeHtml(raw) then
        return { title = title, html = Text.htmlBodyFragment(raw) }
    end
    return { title = title, text = raw }
end

return Mapper
