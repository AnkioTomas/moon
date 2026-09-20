--[[--
书籍高亮收集：会话注解 + notes 表快照。

@module koplugin.book.book.highlights
--]]

--- 首页书摘 / 一言共用展示结构。
---@class BookExcerptQuote
---@field text string
---@field author string
---@field title string
---@field chapter string|nil
---@field source_id string|nil
---@field stable_id string|nil

local Highlights = {}

--- 注解快照是 JSON 数组；坏数据当空，不把解码失败吞成业务空以外的东西。
---@param payload string|nil
---@return table[]
local function decodePayload(payload)
    if type(payload) ~= "string" or payload == "" then return {} end
    local jok, JSON = pcall(require, "json")
    if not jok then return {} end
    local dok, data = pcall(JSON.decode, payload)
    if not dok or type(data) ~= "table" then return {} end
    return data
end

--- 算高亮条目的去重键：有 id 就用 id，否则用文本+章节+页码+起止位置拼串。
--- 拼串用 \0 分隔，避免字段内容里的分隔符造成误撞。
---@param item table 注解条目（会话 annotation 或 notes 表反序列化结果）
---@return string
local function highlightKey(item)
    local id = item.id or item.annotation_id
    if id ~= nil then return "id:" .. tostring(id) end
    local chapter = item.chapter
        or (type(item.chapters) == "table" and item.chapters[1])
        or ""
    return table.concat({
        tostring(item.text or ""), tostring(chapter),
        tostring(item.pageno or item.page or ""),
        tostring(item.pos0 or item.start or ""),
        tostring(item.pos1 or item.finish or ""),
    }, "\0")
end

--- 收集指定书的高亮条目（drawer 划线）。
---@param source_id string|nil
---@param stable_id string|nil
---@param chapter_idx integer|nil
---@param current_items table[]|nil 当前阅读器尚未落库的注解
---@return table[]
function Highlights.collect(source_id, stable_id, chapter_idx, current_items)
    local items, seen = {}, {}
    --- 收一条高亮：只要有 drawer（划线）且文本非空的条目，按 key 去重。
    ---@param item any 非表 / 无 drawer / 空文本一律丢弃
    local function push(item)
        if type(item) ~= "table" or not item.drawer
                or type(item.text) ~= "string" or item.text == "" then
            return
        end
        local key = highlightKey(item)
        if seen[key] then return end
        seen[key] = true
        items[#items + 1] = item
    end

    for _, item in ipairs(current_items or {}) do push(item) end
    if #items > 0 then return items end

    if type(source_id) ~= "string" or type(stable_id) ~= "string" then
        return items
    end
    local ok, NoteDB = pcall(require, "db.note")
    if not ok or not NoteDB then return items end
    local idx = tonumber(chapter_idx) or 0
    local row = NoteDB.get(source_id, stable_id, idx)
    for _, item in ipairs(decodePayload(row and row.payload)) do push(item) end
    return items
end

--- 按轮换索引取一条高亮与出处片段。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@param index integer 1-based 轮换索引
---@param current_items table[]|nil 当前阅读器尚未落库的注解
---@return string|nil text
---@return string|nil source 出处
function Highlights.pick(source_id, stable_id, chapter_idx, index, current_items)
    local items = Highlights.collect(source_id, stable_id, chapter_idx, current_items)
    if #items == 0 then return nil, nil end
    local picked = items[(tonumber(index) or 0) % #items + 1]
    local parts = {}
    local chapter = picked.chapter
        or (type(picked.chapters) == "table" and picked.chapters[1])
    if type(chapter) == "string" and chapter ~= "" then
        parts[#parts + 1] = chapter
    end
    local page = tonumber(picked.pageno) or tonumber(picked.page)
    if page and page > 0 then
        local T = require("ffi/util").template
        local _ = require("gettext")
        parts[#parts + 1] = T(_("第 %1 页"), page)
    end
    local _ = require("gettext")
    local source = #parts > 0 and table.concat(parts, " · ") or _("来自当前书籍高亮")
    return picked.text, source
end

--- 从 notes 全表收划线，带上书名作者与身份。首页书摘用这个，不跟当前书绑死。
---@return { text: string, author: string, title: string, chapter: string, source_id: string, stable_id: string }[]
function Highlights.collectAll()
    local items = {}
    local ok, NoteDB = pcall(require, "db.note")
    if not ok or not NoteDB then return items end
    local bok, BookDB = pcall(require, "db.book")
    local books = {}
    local function bookOf(source_id, stable_id)
        local key = tostring(source_id) .. "\0" .. tostring(stable_id)
        if books[key] == nil then
            books[key] = (bok and BookDB and BookDB.get(source_id, stable_id)) or false
        end
        return books[key] or nil
    end
    local seen = {}
    for _, row in ipairs(NoteDB.all()) do
        local book = bookOf(row.source_id, row.stable_id)
        for _, item in ipairs(decodePayload(row.payload)) do
            if type(item) == "table" and item.drawer
                    and type(item.text) == "string" and item.text ~= "" then
                local key = highlightKey(item) .. "\0" .. tostring(row.source_id)
                    .. "\0" .. tostring(row.stable_id)
                if not seen[key] then
                    seen[key] = true
                    local chapter = item.chapter
                        or (type(item.chapters) == "table" and item.chapters[1])
                    items[#items + 1] = {
                        text = item.text,
                        author = book and book.authors or "",
                        title = book and book.title or "",
                        chapter = type(chapter) == "string" and chapter or "",
                        source_id = row.source_id,
                        stable_id = row.stable_id,
                    }
                end
            end
        end
    end
    return items
end

--- 全库随机一条书摘。有多条时躲开上一句。
---@param avoid string|nil
---@return BookExcerptQuote|nil
function Highlights.random(avoid)
    local items = Highlights.collectAll()
    if #items == 0 then return nil end
    local i = math.random(#items)
    if #items > 1 and avoid and items[i].text == avoid then
        i = i % #items + 1
    end
    local picked = items[i]
    if picked.author == "" and picked.title == "" then
        local _ = require("gettext")
        picked.title = picked.chapter ~= "" and picked.chapter or _("书摘")
    end
    return picked
end

return Highlights
