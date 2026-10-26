--[[--
书籍高亮收集：notes 表快照。

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
local Normalize = require("book.note.normalize")
local NoteDB = require("book.note_db")

--- 有 drawer（划线）且文本非空才算高亮。
---@param item any
---@return boolean
local function isHighlight(item)
    return type(item) == "table" and item.drawer ~= nil
        and type(item.text) == "string" and item.text ~= ""
end

---@param item table
---@return string|nil
local function chapterOf(item)
    local chapter = item.chapter or (type(item.chapters) == "table" and item.chapters[1])
    return type(chapter) == "string" and chapter or nil
end

--- 算高亮条目的去重键：有 id 就用 id，否则用文本+章节+页码+起止位置拼串。
--- 拼串用 \0 分隔，避免字段内容里的分隔符造成误撞。
--- 分页文档的 pos 是表，tostring 只得到地址，内容相同的两条去不了重。
local function posKey(p)
    if type(p) == "table" then return tostring(p.page) .. "," .. tostring(p.x) .. "," .. tostring(p.y) end
    return tostring(p or "")
end

---@param item table 注解条目（会话 annotation 或 notes 表反序列化结果）
---@return string
local function highlightKey(item)
    local id = item.id or item.annotation_id
    if id ~= nil then return "id:" .. tostring(id) end
    return table.concat({
        item.text, chapterOf(item) or "",
        tostring(item.pageno or item.page or ""),
        posKey(item.pos0 or item.start),
        posKey(item.pos1 or item.finish),
    }, "\0")
end

--- 收集指定书的高亮条目（drawer 划线）。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@return table[]
function Highlights.collect(source_id, stable_id, chapter_idx)
    local items, seen = {}, {}
    local row = NoteDB.get(source_id, stable_id, chapter_idx)
    for _idx, item in ipairs(Normalize.decode(row and row.payload) or {}) do
        if isHighlight(item) then
            local key = highlightKey(item)
            if not seen[key] then
                seen[key] = true
                items[#items + 1] = item
            end
        end
    end
    return items
end

--- 按轮换索引取一条高亮与出处片段。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@param index integer 1-based 轮换索引
---@return string|nil text
---@return string|nil source 出处
function Highlights.pick(source_id, stable_id, chapter_idx, index)
    local items = Highlights.collect(source_id, stable_id, chapter_idx)
    if #items == 0 then return nil, nil end
    local picked = items[index % #items + 1]
    local parts = {}
    local chapter = chapterOf(picked)
    if chapter and chapter ~= "" then
        parts[#parts + 1] = chapter
    end
    local _ = require("gettext")
    local page = tonumber(picked.pageno) or tonumber(picked.page)
    if page and page > 0 then
        parts[#parts + 1] = require("ffi/util").template(_("第 %1 页"), page)
    end
    local source = #parts > 0 and table.concat(parts, " · ") or _("来自当前书籍高亮")
    return picked.text, source
end

--- 从 notes 全表收划线，带上书名作者与身份。首页书摘用这个，不跟当前书绑死。
---@return BookExcerptQuote[]
function Highlights.collectAll()
    local items = {}
    local seen = {}
    for _idx, row in ipairs(NoteDB.allWithBook()) do
        for _idx, item in ipairs(Normalize.decode(row.payload) or {}) do
            local key = isHighlight(item)
                and highlightKey(item) .. "\0" .. row.source_id .. "\0" .. row.stable_id
            if key and not seen[key] then
                seen[key] = true
                items[#items + 1] = {
                    text = item.text,
                    author = row.authors,
                    title = row.title,
                    chapter = chapterOf(item) or "",
                    source_id = row.source_id,
                    stable_id = row.stable_id,
                }
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
