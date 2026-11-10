--[[--
高亮与笔记的只读查询：跨书列表、书籍筛选项、单条详情、Markdown 导出。
逐行走 NoteDB.each，不把全部 payload 收进一张数组。写路径在 book.note.mutate。

@module koplugin.book.features.notes.query
--]]

local Note = require("book.note")
local Text = require("utils.text")
local NoteDB = require("book.note_db")
local Normalize = require("book.note.normalize")
local Paths = require("utils.paths")
local logger = require("utils.log")

local Query = {}

Query.PAGE = 30
Query.EXCERPT = 100

---@param item table
---@return boolean
local function isTombstone(item)
    -- 微信/Kavita 墓碑在快照里可能是 true 或 1，按真值判断。
    return item.wr_deleted or item.kavita_deleted or false
end

--- 与 ReaderBookmark.getBookmarkType / book_notes.annotationType 同一规则。
---@param item table
---@return string
function Query.annotationType(item)
    local drawer = item.drawer
    if type(drawer) ~= "string" or drawer == "" then
        return "bookmark"
    end
    local note = item.note
    if type(note) == "string" and note ~= "" then
        return "note"
    end
    return "highlight"
end

---@param item table
---@return boolean
function Query.isListable(item)
    if type(item) ~= "table" or isTombstone(item) then
        return false
    end
    if type(item.text) ~= "string" or item.text == "" then
        return false
    end
    local kind = Query.annotationType(item)
    return kind == "highlight" or kind == "note"
end

---@param text any
---@param limit integer
---@return string
local function excerpt(text, limit)
    if type(text) ~= "string" or text == "" then
        return ""
    end
    local flat = text:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    if #flat <= limit then
        return flat
    end
    -- 按字节上限截，但不切断多字节字符，避免 JSON 变成非法 UTF-8。
    return Text.truncateUtf8(flat, limit) .. "…"
end

---@param item table
---@return string
local function itemTime(item)
    local t = item.datetime_updated or item.datetime
    return type(t) == "string" and t or ""
end

---@param a string
---@param b string
---@return boolean
local function contains(haystack, needle)
    if needle == "" then
        return true
    end
    return (haystack or ""):lower():find(needle, 1, true) ~= nil
end

---@param row table
---@param item table
---@return table
local function listDto(row, item)
    return {
        key = Note.itemKey(row.source_id, row.stable_id, row.chapter_idx, item),
        source_id = row.source_id,
        stable_id = row.stable_id,
        chapter_idx = row.chapter_idx,
        title = row.title or "",
        authors = row.authors or "",
        chapter = type(item.chapter) == "string" and item.chapter or "",
        type = Query.annotationType(item),
        text = excerpt(item.text, Query.EXCERPT),
        note = excerpt(item.note, Query.EXCERPT),
        color = type(item.color) == "string" and item.color or nil,
        drawer = type(item.drawer) == "string" and item.drawer or nil,
        datetime = itemTime(item),
        dirty = (tonumber(row.sync_status) or 1) == 0,
    }
end

---@param row table
---@param source_id string|nil
---@param stable_id string|nil
---@return boolean
local function rowMatches(row, source_id, stable_id)
    if source_id and source_id ~= "" and row.source_id ~= source_id then
        return false
    end
    if stable_id and stable_id ~= "" and row.stable_id ~= stable_id then
        return false
    end
    return true
end

---@param dto table
---@param q string
---@param typ string|nil
---@return boolean
local function dtoMatches(dto, q, typ)
    if typ == "highlight" or typ == "note" then
        if dto.type ~= typ then
            return false
        end
    end
    if q == "" then
        return true
    end
    return contains(dto.text, q) or contains(dto.note, q) or contains(dto.title, q)
        or contains(dto.chapter, q) or contains(dto.authors, q)
end

---@param params table|nil
---@return { items: table[], page: integer, pages: integer, total: integer }
function Query.list(params)
    params = params or {}
    local page = math.max(1, math.floor(tonumber(params.page) or 1))
    local q = type(params.q) == "string" and params.q:lower():match("^%s*(.-)%s*$") or ""
    local typ = type(params.type) == "string" and params.type or nil
    local source_id = params.source_id
    local stable_id = params.stable_id
    local matched = {}
    NoteDB.each(function(row)
        if not rowMatches(row, source_id, stable_id) then
            return
        end
        local items = Normalize.decode(row.payload)
        if not items then
            return
        end
        for _idx, item in ipairs(items) do
            if Query.isListable(item) then
                local dto = listDto(row, item)
                if dtoMatches(dto, q, typ) then
                    matched[#matched + 1] = dto
                end
            end
        end
    end)
    table.sort(matched, function(a, b)
        if a.datetime ~= b.datetime then
            return a.datetime > b.datetime
        end
        return a.key > b.key
    end)
    local total = #matched
    local pages = math.max(1, math.ceil(total / Query.PAGE))
    if page > pages then
        page = pages
    end
    local from = (page - 1) * Query.PAGE + 1
    local out = {}
    for i = from, math.min(from + Query.PAGE - 1, total) do
        out[#out + 1] = matched[i]
    end
    return { items = out, page = page, pages = pages, total = total }
end

---@param params table|nil
---@return { books: table[], page: integer, pages: integer, total: integer }
function Query.books(params)
    params = params or {}
    local page = math.max(1, math.floor(tonumber(params.page) or 1))
    local q = type(params.q) == "string" and params.q:lower():match("^%s*(.-)%s*$") or ""
    local typ = type(params.type) == "string" and params.type or nil
    local by, order = {}, {}
    NoteDB.each(function(row)
        local items = Normalize.decode(row.payload)
        if not items then
            return
        end
        local n = 0
        for _idx, item in ipairs(items) do
            if Query.isListable(item) then
                local dto = listDto(row, item)
                if dtoMatches(dto, q, typ) then
                    n = n + 1
                end
            end
        end
        if n == 0 then
            return
        end
        local id = row.source_id .. "\0" .. row.stable_id
        local book = by[id]
        if not book then
            book = {
                source_id = row.source_id,
                stable_id = row.stable_id,
                title = row.title or "",
                authors = row.authors or "",
                count = 0,
            }
            by[id] = book
            order[#order + 1] = book
        end
        book.count = book.count + n
        if book.title == "" and row.title and row.title ~= "" then
            book.title = row.title
            book.authors = row.authors or ""
        end
    end)
    table.sort(order, function(a, b)
        local at, bt = a.title ~= "" and a.title or a.stable_id, b.title ~= "" and b.title or b.stable_id
        if at ~= bt then
            return at < bt
        end
        return a.stable_id < b.stable_id
    end)
    local total = #order
    local pages = math.max(1, math.ceil(total / Query.PAGE))
    if page > pages then
        page = pages
    end
    local from = (page - 1) * Query.PAGE + 1
    local out = {}
    for i = from, math.min(from + Query.PAGE - 1, total) do
        out[#out + 1] = order[i]
    end
    return { books = out, page = page, pages = pages, total = total }
end

---@param key string
---@return table|nil, string|nil
function Query.item(key)
    local parsed = Note.parseItemKey(key)
    if not parsed then
        return nil, "invalid key"
    end
    local row = NoteDB.get(parsed.source_id, parsed.stable_id, parsed.chapter_idx)
    if not row then
        return nil, "not found"
    end
    -- 书名不在 notes 行里：走一次 each 太重，按身份查书。
    local book = require("book.books_db").get(parsed.source_id, parsed.stable_id)
    local items = Normalize.decode(row.payload)
    if not items then
        return nil, "invalid snapshot"
    end
    for _idx, item in ipairs(items) do
        if Query.isListable(item) and Note.itemKey(row.source_id, row.stable_id, row.chapter_idx, item) == key then
            return {
                key = key,
                source_id = row.source_id,
                stable_id = row.stable_id,
                chapter_idx = row.chapter_idx,
                title = book and book.title or "",
                authors = book and book.authors or "",
                chapter = type(item.chapter) == "string" and item.chapter or "",
                type = Query.annotationType(item),
                text = item.text,
                note = type(item.note) == "string" and item.note or "",
                color = item.color,
                drawer = item.drawer,
                datetime = item.datetime,
                datetime_updated = item.datetime_updated,
                dirty = (tonumber(row.sync_status) or 1) == 0,
            }
        end
    end
    return nil, "not found"
end

---@param heading string
---@return string
local function mdEscape(heading)
    return (heading:gsub("[\r\n]+", " "):gsub("^#+", ""))
end

--- 把全部可列出的条目写成 Markdown 临时文件，供 download() 按路径流式发送。
---@return string|nil path
---@return string|nil err
function Query.exportFile()
    local books, order = {}, {}
    NoteDB.each(function(row)
        local items = Normalize.decode(row.payload)
        if not items then
            return
        end
        local id = row.source_id .. "\0" .. row.stable_id
        for _idx, item in ipairs(items) do
            if Query.isListable(item) then
                local book = books[id]
                if not book then
                    book = {
                        title = (row.title and row.title ~= "") and row.title or row.stable_id,
                        authors = row.authors or "",
                        chapters = {},
                        chapter_order = {},
                    }
                    books[id] = book
                    order[#order + 1] = book
                end
                local chapter = type(item.chapter) == "string" and item.chapter or ""
                local bucket = book.chapters[chapter]
                if not bucket then
                    bucket = {}
                    book.chapters[chapter] = bucket
                    book.chapter_order[#book.chapter_order + 1] = chapter
                end
                bucket[#bucket + 1] = {
                    text = item.text,
                    note = type(item.note) == "string" and item.note or "",
                    datetime = itemTime(item),
                }
            end
        end
    end)
    local path = Paths.tmpname(".md")
    local f, err = io.open(path, "wb")
    if not f then
        logger.warn("notes export open failed", path, err)
        return nil, err or "open failed"
    end
    f:write("# 高亮与笔记\n\n")
    for _idx, book in ipairs(order) do
        f:write("# " .. mdEscape(book.title) .. "\n")
        if book.authors ~= "" then
            f:write(book.authors .. "\n")
        end
        f:write("\n")
        for _c, chapter in ipairs(book.chapter_order) do
            if chapter ~= "" then
                f:write("## " .. mdEscape(chapter) .. "\n\n")
            end
            for _i, item in ipairs(book.chapters[chapter]) do
                f:write("> " .. (item.text:gsub("\n", "\n> ")) .. "\n")
                if item.note ~= "" then
                    f:write("\n" .. item.note .. "\n")
                end
                f:write("\n")
            end
        end
        f:write("\n")
    end
    f:close()
    return path
end

return Query
