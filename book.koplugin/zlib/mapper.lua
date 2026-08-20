--[[--
Z-Library wire → 书城展示对象。

@module koplugin.book.zlib.mapper
--]]

local BookListResult = require("types.book_list")
local Text = require("utils.text")
local _ = require("gettext")

local Mapper = {}

--- 将 eAPI 的 id 与 hash 编码为源内稳定身份。
---@param id string|number|nil
---@param hash string|number|nil
---@return string|nil
function Mapper.identity(id, hash)
    if id == nil or hash == nil then return nil end
    id, hash = tostring(id), tostring(hash)
    if id == "" or hash == "" then return nil end
    return id .. ":" .. hash
end

--- 拆解 `id:hash` 形式的稳定身份。
---@param stable_id string|nil
---@return string|nil id
---@return string|nil hash
function Mapper.parse(stable_id)
    if type(stable_id) ~= "string" then return nil, nil end
    return stable_id:match("^([^:]+):(.+)$")
end

--- 只接受可直接请求的 HTTP(S) 封面地址。
---@param value any
---@return string|nil
local function coverUrl(value)
    return type(value) == "string" and value:match("^https?://") and value or nil
end

--- eAPI 单书记录转换为统一 Book 展示对象。
---@param row table|nil
---@return Book|nil
function Mapper.book(row)
    if type(row) ~= "table" then return nil end
    local stable_id = Mapper.identity(row.id, row.hash)
    if not stable_id then return nil end
    local cover = coverUrl(row.cover)
    local description = row.description or row.intro
    if type(description) == "string" then
        description = Text.trim(description:gsub("<[^>]+>", " "):gsub("%s+", " "))
    end
    return {
        source_id = "zlib", stable_id = stable_id,
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

--- eAPI 搜索或热门书单转换为统一分页结果。
---@param wire table|nil
---@return BookListResult
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
