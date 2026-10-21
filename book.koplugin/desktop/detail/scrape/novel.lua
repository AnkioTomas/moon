--[[--
网文站点元数据搜索：七猫、晋江、起点、番茄、长佩、潇湘都走各自数据源自带的搜索接口

返回字段对齐统一格式（见 weread.lua），不登录即可用

@module koplugin.book.desktop.detail.scrape.novel
--]]

local Text = require("utils.text")

local Novel = {}

--- 数据源 Book[] → 统一行。
---@param source_id string
---@param books Book[]
---@return table[]
function Novel.fromBooks(source_id, books)
    local out = {}
    for _idx, book in ipairs(books) do
        out[#out + 1] = {
            title = Text.trim(book.title),
            author = Text.trim(book.authors),
            intro = book.intro or "",
            tags = book.category and book.category ~= "" and { book.category } or {},
            cover_url = book.cover or "",
            source = source_id,
        }
    end
    return out
end

--- 经数据源自带的 searchAsync 搜索。
---@param source_id string
---@param query string
---@param cb fun(results: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Novel.viaSource(source_id, query, cb)
    local source, err = require("source.registry").create(source_id)
    if not source then
        cb(nil, err)
        return nil
    end
    return source:searchAsync(query, function(res, serr)
        cb(res and Novel.fromBooks(source_id, res.data), serr)
    end)
end

return Novel
