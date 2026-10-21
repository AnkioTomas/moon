--[[--
数据源元数据搜索：微信读书、七猫、晋江、起点、番茄、长佩、潇湘都走各自数据源自带的 searchAsync，
这里只把 Book 映射成刮削统一行（title/author/intro/tags/cover_url/publisher/year/isbn/rating/series/source）

@module koplugin.book.desktop.detail.scrape.novel
--]]

local Text = require("utils.text")

local Novel = {}

--- 数据源 Book[] → 统一行。
---@param label string 结果来源标记（评分来源、结果页标题）
---@param books Book[]
---@return table[]
function Novel.fromBooks(label, books)
    local out = {}
    for _idx, book in ipairs(books) do
        local meta = book.meta or {}
        local score = meta.rating and tonumber(meta.rating.score) or 0
        out[#out + 1] = {
            title = Text.trim(book.title),
            author = Text.trim(book.authors),
            intro = book.intro or "",
            tags = book.category and book.category ~= "" and { book.category } or {},
            cover_url = book.cover or "",
            publisher = Text.trim(meta.publisher),
            year = tostring(meta.published or ""):match("%d%d%d%d") or "",
            isbn = Text.trim(meta.isbn),
            rating = score > 0 and string.format("%.1f", score) or "",
            series = Text.trim(book.series),
            source = label,
        }
    end
    return out
end

--- 经数据源自带的 searchAsync 搜索。
---@param source_id string
---@param query string
---@param cb fun(results: table[]|nil, err: string|nil)
---@param label string|nil 结果来源标记，缺省同 source_id
---@return { cancel: fun() }|nil
function Novel.viaSource(source_id, query, cb, label)
    local source, err = require("source.registry").create(source_id)
    if not source then
        cb(nil, err)
        return nil
    end
    return source:searchAsync(query, function(res, serr)
        cb(res and Novel.fromBooks(label or source_id, res.data), serr)
    end)
end

return Novel
