--[[--
拷贝漫画 App API 数据映射。

@module koplugin.book.source.copymanga.mapper
--]]

local BookListResult = require("types.book_list")

local Mapper = {}
local SOURCE_ID = "copymanga"

---@param rows table[]|nil
---@return string|nil
local function names(rows)
    local list = {}
    for _, row in ipairs(rows or {}) do
        if type(row) == "table" and type(row.name) == "string" and row.name ~= "" then
            list[#list + 1] = row.name
        end
    end
    return #list > 0 and table.concat(list, ", ") or nil
end

---@param row table|nil
---@return table|nil
local function comicOf(row)
    if type(row) ~= "table" then return nil end
    if type(row.comic) == "table" then return row.comic end
    return row
end

---@param row table|nil
---@return Book|nil
function Mapper.book(row)
    row = comicOf(row)
    if type(row) ~= "table" or type(row.path_word) ~= "string" or row.path_word == "" then
        return nil
    end
    return {
        source_id = SOURCE_ID,
        stable_id = row.path_word,
        title = row.name,
        authors = names(row.author),
        category = row.category or names(row.theme),
        intro = row.intro or row.brief,
        cover = row.cover,
        percent = tonumber(row.percent) or 0,
        in_library = row.in_library,
    }
end

--- 列表 JSON → 标准书城列表。搜索 / 发现 / 收藏共用。
---@param wire table
---@return BookListResult
function Mapper.search(wire)
    local root = type(wire.results) == "table" and wire.results or {}
    local books = {}
    for _, row in ipairs(root.list or {}) do
        local book = Mapper.book(row)
        if book then books[#books + 1] = book end
    end
    return BookListResult.new(books, tonumber(root.total) or #books)
end

--- 收藏列表：同一 list 结构，标记在架。
---@param wire table
---@return BookListResult
function Mapper.collect(wire)
    local result = Mapper.search(wire)
    for _, book in ipairs(result.data) do
        book.in_library = true
    end
    return result
end

--- comic2 JSON → 书籍元数据。
---@param stable_id string
---@param wire table
---@return Book|nil
function Mapper.detail(stable_id, wire)
    local results = type(wire) == "table" and wire.results or nil
    local comic = type(results) == "table" and results.comic or nil
    if type(comic) ~= "table" then return nil end
    return Mapper.book({
        path_word = (type(comic.path_word) == "string" and comic.path_word ~= "")
            and comic.path_word or stable_id,
        name = comic.name,
        author = comic.author,
        theme = comic.theme,
        brief = comic.brief,
        intro = comic.intro,
        cover = comic.cover,
        category = comic.category,
    })
end

--- comic2 JSON → 云端收藏用的漫画 uuid。
---@param wire table|nil
---@return string|nil
function Mapper.comicId(wire)
    local results = type(wire) == "table" and wire.results or nil
    local comic = type(results) == "table" and results.comic or nil
    local uuid = type(comic) == "table" and comic.uuid or nil
    if type(uuid) == "string" and uuid ~= "" then return uuid end
    return nil
end

--- comic2.groups → 默认组在前的分组列表。
---@param wire table|nil
---@return { path_word: string, name: string }[]
function Mapper.groups(wire)
    local raw = type(wire) == "table" and wire.results
    raw = type(raw) == "table" and raw.groups or nil
    local list = {}
    if type(raw) == "table" then
        for _, group in pairs(raw) do
            if type(group) == "table"
                and type(group.path_word) == "string"
                and group.path_word ~= ""
            then
                list[#list + 1] = {
                    path_word = group.path_word,
                    name = type(group.name) == "string" and group.name ~= ""
                        and group.name or group.path_word,
                }
            end
        end
        table.sort(list, function(a, b)
            if a.path_word == "default" then return true end
            if b.path_word == "default" then return false end
            return a.path_word < b.path_word
        end)
    end
    if #list == 0 then
        return { { path_word = "default", name = "默认" } }
    end
    return list
end

--- 分组章节行 → 连续目录；非默认组加组名前缀。
---@param rows table[]|nil
---@return BookChapter[]|nil
function Mapper.chapters(rows)
    local chapters, seen = {}, {}
    for _, row in ipairs(rows or {}) do
        local uid = type(row) == "table" and row.uuid or nil
        if type(uid) == "string" and uid ~= "" and not seen[uid] then
            seen[uid] = true
            local title = tostring(row.name or uid)
            if row.group_path and row.group_path ~= "default"
                and type(row.group_name) == "string" and row.group_name ~= ""
            then
                title = row.group_name .. " · " .. title
            end
            chapters[#chapters + 1] = {
                idx = #chapters + 1,
                uid = uid,
                title = title,
                depth = 1,
            }
        end
    end
    return #chapters > 0 and chapters or nil
end

return Mapper
