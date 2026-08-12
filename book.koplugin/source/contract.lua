--[[--
Source 契约（文档约定；Lua 无 interface）

统一字段（适配器可在原字段旁补充别名，勿删服务端字段）：
  id, title, authors, cover_id, progress, finished, extra

能力位 capabilities：
  store, stats, progress_sync, stats_import, search, filters

失败语义：一律 data, err；不吞错。

@module koplugin.book.source.contract
--]]

local Contract = {}

function Contract.defaultCapabilities()
    return {
        store = false,
        stats = false,
        progress_sync = false,
        stats_import = false,
        search = false,
        filters = false,
    }
end

--- 在不破坏原字段的前提下补齐统一别名
function Contract.normalizeBook(book)
    if type(book) ~= "table" then
        return book
    end
    book.id = book.id or book.filename
    book.title = book.title or book.bookName or book.name
    book.authors = book.authors or book.author
    book.cover_id = book.cover_id or book.filename or book.id
    if book.progress == nil then
        book.progress = book.progressPercent
    end
    if book.finished == nil and book.progressPercent ~= nil then
        local p = tonumber(book.progressPercent)
        book.finished = p and p >= 100
    end
    return book
end

function Contract.normalizeList(res)
    if type(res) ~= "table" then
        return res
    end
    local list = res.data or res.list or res.books
    if type(list) == "table" then
        for i, b in ipairs(list) do
            list[i] = Contract.normalizeBook(b)
        end
    end
    return res
end

return Contract
