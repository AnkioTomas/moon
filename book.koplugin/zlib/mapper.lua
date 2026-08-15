--[[--
Z-Library wire → 书城展示对象。

@module koplugin.book.zlib.mapper
--]]

local BookRef = require("types.book").BookRef
local BookListResult = require("types.book_list")
local _ = require("gettext")

local Mapper = {}

function Mapper.identity(id, hash)
    if id == nil or hash == nil then return nil end
    id, hash = tostring(id), tostring(hash)
    if id == "" or hash == "" then return nil end
    return id .. ":" .. hash
end

function Mapper.parse(stable_id)
    if type(stable_id) ~= "string" then return nil, nil end
    return stable_id:match("^([^:]+):(.+)$")
end

local function coverUrl(value)
    return type(value) == "string" and value:match("^https?://") and value or nil
end

function Mapper.book(row)
    if type(row) ~= "table" then return nil end
    local stable_id = Mapper.identity(row.id, row.hash)
    if not stable_id then return nil end
    local cover = coverUrl(row.cover)
    local description = row.description or row.intro
    if type(description) == "string" then
        description = description:gsub("<[^>]+>", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    end
    return {
        ref = BookRef.new("zlib", stable_id),
        title = (type(row.title) == "string" and row.title ~= "") and row.title or _("未知书名"),
        authors = row.author or row.authors,
        percent = 0,
        category = row.language,
        series = row.series,
        intro = description,
        cover = cover,
        cover_url = cover,
        filesize = tonumber(row.filesize),
        format = row.extension or row.format,
    }
end

function Mapper.list(wire)
    if type(wire) ~= "table" then return BookListResult.empty() end
    local rows = wire.books or (wire.exactMatch and wire.exactMatch.books) or {}
    local books = {}
    for _, row in ipairs(rows) do
        local book = Mapper.book(row)
        if book then books[#books + 1] = book end
    end
    local count = wire.pagination and tonumber(wire.pagination.total_items)
        or tonumber(wire.exactBooksCount)
        or #books
    return BookListResult.new(books, count)
end

return Mapper
