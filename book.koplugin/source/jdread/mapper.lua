--[[--
京东读书 wire → 领域对象。

@module koplugin.book.source.jdread.mapper
--]]

local Book = require("types.book").Book
local BookListResult = require("types.book_list")
local ProgressPosition = require("types.book_progress")
local Text = require("utils.text")

local Mapper = {}
local SOURCE_ID = "jdread"

---@param value any
---@return string|nil
local function coverUrl(value)
    if type(value) ~= "string" or value == "" then return nil end
    if value:sub(1, 2) == "//" then value = "https:" .. value end
    if not value:match("^https?://") then return nil end
    return (value:gsub("%.dpg$", ""))
end

---@param row table|nil
---@return Book|nil, string|nil
function Mapper.book(row)
    if type(row) ~= "table" then return nil end
    row = type(row.ebook) == "table" and row.ebook or row
    local id = row.ebook_id or row.ebookId or row.product_id
        or row.book_id or row.bookId or row.id
    if id == nil or tostring(id) == "" then return nil end
    local cover = coverUrl(
        row.image_url or row.imageUrl or row.logo or row.cover or row.cover_url
    )
    local percent = row.percent or row.progress or row.read_progress or row.readProgress
    local category = row.category
    if category == nil and type(row.cate_third_names) == "table" then
        category = table.concat(row.cate_third_names, ", ")
    end
    return {
        source_id = SOURCE_ID,
        stable_id = tostring(id),
        title = row.name or row.product_name
            or row.ebook_name or row.ebookName or row.book_name or row.bookName,
        authors = row.author or row.authors,
        percent = Book.clampPercent(percent),
        category = category,
        intro = row.intro or row.info or row.content_info or row.description or row.summary,
        cover = cover,
    }, cover
end

--- 京东书架 wire → BookListResult。
---@param wire table
---@param on_cover fun(stable_id: string, url: string)|nil
---@return BookListResult
function Mapper.shelfList(wire, on_cover)
    local root = type(wire.data) == "table" and wire.data or wire
    local rows = root.books or root.ebooks or root.list or root.items or {}
    local books = {}
    for _, row in ipairs(rows) do
        local book, cover = Mapper.book(row)
        if book then
            if cover and on_cover then on_cover(book.stable_id, cover) end
            books[#books + 1] = book
        end
    end
    return BookListResult.new(books, root.total or root.total_count)
end

--- 京东书城搜索 / 推荐 wire → BookListResult。
---@param wire table
---@param on_cover fun(stable_id: string, url: string)|nil
---@return BookListResult
function Mapper.storeList(wire, on_cover)
    local root = type(wire.data) == "table" and wire.data or wire
    local rows = root.product_search_infos or root.items or root
    local books = {}
    for _, row in ipairs(rows) do
        local book, cover = Mapper.book(row)
        if book then
            if cover and on_cover then on_cover(book.stable_id, cover) end
            books[#books + 1] = book
        end
    end
    return BookListResult.new(books, root.total_count)
end

--- cread 目录 wire → BookChapter[]。
---@param wire table
---@return BookChapter[]|nil
function Mapper.chapters(wire)
    local rows = wire.catalogList or wire.catalog_list
    if type(rows) ~= "table" then return nil end
    table.sort(rows, function(a, b)
        return (tonumber(a.sort) or 0) < (tonumber(b.sort) or 0)
    end)
    local chapters = {}
    for _, row in ipairs(rows) do
        local uid = row.catalogId or row.catalog_id
        if uid ~= nil then
            chapters[#chapters + 1] = {
                idx = #chapters + 1,
                source_idx = tostring(row.sort or (#chapters + 1)),
                uid = tostring(uid),
                title = tostring(row.catalogName or row.catalog_name or ("第" .. (#chapters + 1) .. "章")),
                depth = math.max(1, math.floor(tonumber(row.level) or 0) + 1),
            }
        end
    end
    if #chapters == 0 then return nil end
    chapters[1].toc_version = 1
    return chapters
end

--- cread 正文 wire → 标准章节内容。
---@param wire table
---@param title string|nil
---@return ChapterContentPayload|nil
function Mapper.content(wire, title)
    local parts = wire.contentList or wire.content_list
    if type(parts) ~= "table" then return nil end
    local html = {}
    for _, part in ipairs(parts) do
        local content = type(part) == "table" and part.content or part
        if type(content) == "string" and content ~= "" then
            html[#html + 1] = Text.htmlBodyFragment(content)
        end
    end
    if #html == 0 then return nil end
    return { title = title, html = table.concat(html, "\n") }
end

--- marker/sync wire → ProgressPosition 与章节 uid。
---@param wire table
---@return ProgressPosition|nil, string|nil
function Mapper.progress(wire)
    local groups = wire.data
    local markers = type(groups) == "table" and groups[1] and groups[1].list
    if type(markers) ~= "table" then return nil end
    local current
    for _, marker in ipairs(markers) do
        if type(marker) == "table" and tonumber(marker.data_type) == 0
            and (not current or (tonumber(marker.version) or 0) > (tonumber(current.version) or 0)) then
            current = marker
        end
    end
    if not current then return nil end
    return {
        fraction = ProgressPosition.clampFraction(current.percent),
        chapter_title = current.epub_chapter_title,
        updated_at = tonumber(current.version or current.created_at),
    }, current.chapter_id and tostring(current.chapter_id) or nil
end

return Mapper
