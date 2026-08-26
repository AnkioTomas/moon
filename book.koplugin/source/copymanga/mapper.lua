--[[--
拷贝漫画 wire → 领域对象

@module koplugin.book.source.copymanga.mapper
--]]

local Book = require("types.book").Book
local BookListResult = require("types.book_list")

local Mapper = {}

local SOURCE_ID = "copymanga"

---@param item table|nil
---@return table|nil
local function extractComic(item)
    if type(item) ~= "table" then
        return nil
    end
    if type(item.comic) == "table" then
        return item.comic
    end
    return item
end

---@param comic table|nil
---@return string|nil
local function authorName(comic)
    if type(comic) ~= "table" then
        return nil
    end
    local authors = comic.author
    if type(authors) == "table" and authors[1] then
        local first = authors[1]
        if type(first) == "table" then
            return first.name
        end
        return tostring(first)
    end
    if type(authors) == "string" and authors ~= "" then
        return authors
    end
end

--- 搜索/收藏行 → Book。
---@param item table|nil
---@return Book|nil, string|nil cover_url
function Mapper.book(item)
    local comic = extractComic(item)
    if type(comic) ~= "table" then
        return nil
    end
    local id = comic.path_word
    if type(id) ~= "string" or id == "" then
        return nil
    end
    local cover = type(comic.cover) == "string" and comic.cover or nil
    return {
        source_id = SOURCE_ID,
        stable_id = id,
        title = comic.name or id,
        authors = authorName(comic),
        category = "漫画",
        cover = cover,
    }, cover
end

--- 列表 wire → BookListResult。
---@param wire table|nil
---@param on_cover fun(stable_id: string, url: string)|nil
---@return BookListResult
function Mapper.list(wire, on_cover)
    local results = type(wire) == "table" and (wire.results or wire) or {}
    local items = results.list or results.items or {}
    local books = {}
    for _, item in ipairs(items) do
        local b, cover = Mapper.book(item)
        if b then
            if cover and on_cover then
                on_cover(b.stable_id, cover)
            end
            books[#books + 1] = b
        end
    end
    local count = tonumber(results.total) or #books
    return BookListResult.new(books, count)
end

--- 详情 wire → Book + 分组章节元数据。
---@param wire table|nil
---@return Book|nil, table[]|nil chapters, string|nil cover_url
function Mapper.detail(wire)
    if type(wire) ~= "table" then
        return nil, nil
    end
    local data = wire.results or wire
    if type(data) ~= "table" then
        return nil, nil
    end
    local comic = data.comic
    if type(comic) ~= "table" then
        return nil, nil
    end
    local id = comic.path_word
    if type(id) ~= "string" or id == "" then
        return nil, nil
    end
    local authors = {}
    for _, a in ipairs(comic.author or {}) do
        if type(a) == "table" and type(a.name) == "string" and a.name ~= "" then
            authors[#authors + 1] = a.name
        end
    end
    local tags = {}
    for _, t in ipairs(comic.theme or {}) do
        if type(t) == "table" and type(t.name) == "string" and t.name ~= "" then
            tags[#tags + 1] = t.name
        end
    end
    local st = comic.status
    local status = type(st) == "table" and st.display or st
    local cover = type(comic.cover) == "string" and comic.cover or nil
    local book = {
        source_id = SOURCE_ID,
        stable_id = id,
        title = comic.name or id,
        authors = #authors > 0 and table.concat(authors, "、") or authorName(comic),
        category = #tags > 0 and table.concat(tags, " / ") or "漫画",
        intro = type(comic.brief) == "string" and comic.brief or nil,
        series = type(status) == "string" and status ~= "" and status or nil,
        cover = cover,
    }
    local groups = {}
    for _, g in pairs(data.groups or {}) do
        if type(g) == "table" and type(g.path_word) == "string" and g.path_word ~= "" then
            groups[#groups + 1] = {
                name = g.name or "默认",
                path_word = g.path_word,
            }
        end
    end
    table.sort(groups, function(a, b)
        if a.path_word == "default" then return true end
        if b.path_word == "default" then return false end
        return a.path_word < b.path_word
    end)
    return book, groups, cover
end

--- 章节分页 wire → 单页条目。
---@param wire table|nil
---@return table[], integer total
function Mapper.chapterPage(wire)
    local results = type(wire) == "table" and (wire.results or wire) or {}
    local list = {}
    for _, e in ipairs(results.list or {}) do
        if type(e) == "table" and type(e.uuid) == "string" and e.uuid ~= "" then
            list[#list + 1] = { id = e.uuid, name = e.name or "" }
        end
    end
    local total = tonumber(results.total) or #list
    return list, total
end

--- 扁平章节列表 → BookChapter[]。
---@param rows table[]
---@return table[]
function Mapper.chapters(rows)
    local out = {}
    for i, row in ipairs(rows or {}) do
        if type(row) == "table" and type(row.id) == "string" and row.id ~= "" then
            out[#out + 1] = {
                idx = i,
                uid = row.id,
                title = row.name ~= "" and row.name or nil,
            }
        end
    end
    return out
end

--- 章节正文 wire → 图片 URL 列表（保序）。
---@param wire table|nil
---@return string[]
function Mapper.chapterPages(wire)
    local results = type(wire) == "table" and (wire.results or wire) or {}
    local ch = results.chapter or {}
    local contents = ch.contents or {}
    local words = ch.words or {}
    local pages = {}
    for i, c in ipairs(contents) do
        if type(c) == "table" then
            local url = c.url
            if type(url) == "string" and url ~= "" then
                url = url:gsub("%.c800x%.", ".c1500x.")
                local order = words[i]
                pages[#pages + 1] = { url = url, order = (tonumber(order) or (i - 1)) + 1 }
            end
        end
    end
    table.sort(pages, function(a, b) return a.order < b.order end)
    local urls = {}
    for _, p in ipairs(pages) do
        urls[#urls + 1] = p.url
    end
    return urls
end

return Mapper
