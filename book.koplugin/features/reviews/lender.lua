--[[--
借段评的来源：本地书和不带段评的章会话书，借某个书源的段评。来源由外部书源经 `reader.paragraph_lender` 挂点登记，
可以登记多个；没人登记就没有关联功能。关联记着借的是哪个来源（`source_id`），没记的旧关联按第一个登记者算。

@module koplugin.book.features.reviews.lender
--]]

local Text = require("utils.text")

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

--- 作者名是否包含用户输入。大小写不敏感，按字面匹配。
---@param name string|nil
---@param author string
---@return boolean
local function authorHit(name, author)
    if author == "" then return true end
    return (name or ""):lower():find(author:lower(), 1, true) ~= nil
end

--- 按书名搜可关联的书目，作者非空时再滤一遍。
--- 来源有 `searchBooksAsync` 用它，否则退到通用书城搜索 `searchAsync`（Book → { book_id, title, author }）。
--- 书名和作者都有时，作者作为第三参交给来源（旧插件忽略多出来的参数）。只填作者时用作者当关键字。
---@param source ParagraphReviewSource
---@param keyword string
---@param cb fun(books: { book_id: string, title: string, author: string|nil }[]|nil, err: string|nil)
---@param author string|nil
---@return { cancel: fun() }|nil
function Lender.search(source, keyword, cb, author)
    keyword = Text.trim(keyword or "")
    author = Text.trim(author or "")
    local query = keyword ~= "" and keyword or author
    if query == "" then cb({}); return nil end
    local api_author = (keyword ~= "" and author ~= "") and author or nil
    local function finish(books, err)
        if not books or author == "" then cb(books, err); return end
        local kept = {}
        for _idx, book in ipairs(books) do
            if authorHit(book.author, author) then kept[#kept + 1] = book end
        end
        cb(kept)
    end
    if source.searchBooksAsync then return source:searchBooksAsync(query, finish, api_author) end
    return source:searchAsync(query, function(res, err)
        if not res then finish(nil, err); return end
        local books = {}
        for _idx, book in ipairs(res.data or {}) do
            local name = book.authors or book.author
            if type(name) == "table" then name = table.concat(name, " / ") end
            books[#books + 1] = { book_id = tostring(book.stable_id), title = book.title or "", author = name }
        end
        finish(books)
    end, api_author)
end

return Lender
