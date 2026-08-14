--[[--
本地文件 → Book 映射

@module koplugin.book.source.local.mapper
--]]

local BookRef = require("types.book").BookRef
local BookListResult = require("types.book_list")

local Mapper = {}

local SOURCE_ID = "local"

--- 从文件名解析标题与作者。
--- 支持格式：
---   "作者 - 书名.ext"
---   "书名 - 作者.ext"
---   "书名.ext"
---@param filename string
---@return string title, string|nil authors
local function parseFilename(filename)
    local name = filename:gsub("%.[^.]+$", "")
    name = name:gsub("[%[%(].-[%]%)]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- "作者 - 书名"（含空格的分隔符优先）
    local a, b = name:match("^(.+)%s+%-%s+(.+)$")
    if a and b then
        return b, a
    end
    -- "书名 - 作者"（无空格分隔符）
    a, b = name:match("^(.+)%-(.+)$")
    if a and b then
        return a, b
    end
    return name, nil
end

--- 本地文件条目 → BookListResult。
--- 元数据（书名/作者/介绍）优先用 client 解析结果，缺失回退文件名解析。
---@param files table[] { name, path, size, mtime, category?, title?, authors?, intro? }
---@return BookListResult
function Mapper.list(files)
    local books = {}
    for _, f in ipairs(files or {}) do
        local title, authors = f.title, f.authors
        if not title or title == "" then
            title, authors = parseFilename(f.name)
        end
        books[#books + 1] = {
            ref = BookRef.new(SOURCE_ID, f.path),
            title = title,
            authors = authors,
            intro = f.intro,
            category = f.category,
            percent = 0,
            filesize = f.size,
        }
    end
    return BookListResult.new(books)
end

--- 由 BookRef 构造详情：优先 books 表缓存（含介绍），否则文件名。
---@param ref BookRef
---@return BookDetail
function Mapper.detailFromRef(ref)
    local cached = require("utils.db.book").get(ref.book_key)
    if cached and type(cached.title) == "string" and cached.title ~= "" then
        return {
            ref = ref,
            title = cached.title,
            authors = cached.authors,
            intro = cached.intro,
            category = cached.category,
            percent = 0,
        }
    end
    local title = ref.stable_id:match("([^/]+)$") or ref.stable_id
    title = title:gsub("%.[^.]+$", "")
    return {
        ref = ref,
        title = title,
        percent = 0,
    }
end

return Mapper
