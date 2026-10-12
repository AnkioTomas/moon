--[[--
拷贝漫画 App API 数据映射。

@module koplugin.book.source.copymanga.mapper
--]]

local Text = require("utils.text")

local Mapper = {}
local SOURCE_ID = "copymanga"

---@param rows table[]|nil
---@return string|nil
local function names(rows)
    local list = {}
    for _idx, row in ipairs(rows or {}) do
        if type(row) == "table" and type(row.name) == "string" and row.name ~= "" then
            list[#list + 1] = row.name
        end
    end
    return #list > 0 and table.concat(list, ", ") or nil
end

--- 回包的 results 表；wire 或 results 不是表时给空表。
---@param wire table|nil
---@return table
local function resultsOf(wire)
    local results = type(wire) == "table" and wire.results
    return type(results) == "table" and results or {}
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
    local intro = row.intro or row.brief
    return {
        source_id = SOURCE_ID,
        stable_id = row.path_word,
        title = row.name,
        authors = names(row.author),
        category = row.category or names(row.theme),
        intro = intro and Text.stripHtml(intro),
        cover = row.cover,
        percent = tonumber(row.percent) or 0,
        deleted = (row.deleted == true or tonumber(row.deleted) == 1) and 1 or nil,
    }
end

--- 收藏行（见 Client:collectAllAsync）→ 在架书。
---@param rows table[]
---@return Book[]
function Mapper.collect(rows)
    local books = {}
    for _idx, row in ipairs(rows) do
        local book = Mapper.book(row)
        if book then
            book.deleted = 0
            books[#books + 1] = book
        end
    end
    return books
end

--- comic2 JSON → 书籍元数据。
---@param wire table
---@return Book|nil
function Mapper.detail(wire)
    return Mapper.book(resultsOf(wire).comic)
end

--- comic2 JSON → 云端收藏用的漫画 uuid。
---@param wire table|nil
---@return string|nil
function Mapper.comicId(wire)
    local comic = resultsOf(wire).comic
    local uuid = type(comic) == "table" and comic.uuid or nil
    if type(uuid) == "string" and uuid ~= "" then return uuid end
    return nil
end

--- comic2.groups → 默认组在前的分组列表。
---@param wire table|nil
---@return { path_word: string, name: string }[]
function Mapper.groups(wire)
    local raw = resultsOf(wire).groups
    local list = {}
    if type(raw) == "table" then
        for _group_key, group in pairs(raw) do
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
    for _idx, row in ipairs(rows or {}) do
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

--- comic2/query wire → 占位进度 + 章节 uuid。browse 为 null 表示从未读过。
--- 云端只有章粒度，fraction 由门面按目录换算。
---@param wire table|nil
---@return ProgressPosition|nil, string|nil
function Mapper.progress(wire)
    local browse = resultsOf(wire).browse
    if type(browse) ~= "table" then return nil end
    local uid = browse.chapter_uuid or browse.chapter_id
    if type(uid) ~= "string" or uid == "" then return nil end
    local title = browse.chapter_name
    return {
        fraction = 0,
        chapter_title = type(title) == "string" and title ~= "" and title or nil,
    }, uid
end

return Mapper
