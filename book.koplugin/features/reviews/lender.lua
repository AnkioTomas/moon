--[[--
借段评的来源：本地书和不带段评的章会话书，借某个书源的段评。来源由外部书源经 `reader.paragraph_lender` 挂点登记，
可以登记多个；没人登记就没有关联功能。关联记着借的是哪个来源（`source_id`），没记的旧关联按第一个登记者算。

@module koplugin.book.features.reviews.lender
--]]

local Lender = {}

---@return { id: string, label: string }[]
function Lender.list()
    return require("utils.extension").list("reader.paragraph_lender")
end

--- 有没有人登记（不创建书源实例，适合判断入口该不该出现）。
---@return boolean
function Lender.registered()
    return #Lender.list() > 0
end

---@param id string|nil nil = 默认（第一个登记者）
---@return { id: string, label: string }|nil
local function entry(id)
    local list = Lender.list()
    if not id then return list[1] end
    for _idx, item in ipairs(list) do
        if item.id == id then return item end
    end
    return nil
end

--- 借段评的书源实例；没登记或建不出来为 nil。
---@param id string|nil 来源 id；nil = 默认
---@return ParagraphReviewSource|nil
function Lender.get(id)
    local item = entry(id)
    if not item then return nil end
    return (require("source.registry").resolve(item.id)) --[[@as ParagraphReviewSource|nil]]
end

--- 关联实际借的来源 id（旧关联没记，按默认）。
---@param link { source_id: string|nil }|nil
---@return string|nil
function Lender.idOf(link)
    if link and link.source_id then return link.source_id end
    local item = entry(nil)
    return item and item.id
end

--- 展示用来源名；多个来源时没指定 id 返回空串由调用方换通用文案。
---@param id string|nil
---@return string
function Lender.label(id)
    local item = entry(id)
    return item and item.label or ""
end

--- 按书名搜可关联的书目。来源有 `searchBooksAsync` 用它，否则退到通用书城搜索 `searchAsync`（Book → { book_id, title, author }）。
---@param source ParagraphReviewSource
---@param keyword string
---@param cb fun(books: { book_id: string, title: string, author: string|nil }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function Lender.search(source, keyword, cb)
    if source.searchBooksAsync then return source:searchBooksAsync(keyword, cb) end
    return source:searchAsync(keyword, function(res, err)
        if not res then cb(nil, err); return end
        local books = {}
        for _idx, book in ipairs(res.data or {}) do
            local author = book.authors or book.author
            if type(author) == "table" then author = table.concat(author, " / ") end
            books[#books + 1] = { book_id = tostring(book.stable_id), title = book.title or "", author = author }
        end
        cb(books)
    end)
end

return Lender
