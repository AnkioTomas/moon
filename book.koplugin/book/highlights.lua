--[[--
书籍高亮收集：会话注解 + notes 表快照。

@module koplugin.book.book.highlights
--]]

local Session = require("ui.reader.session")

local Highlights = {}

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
---@return table[]
function Highlights.collect(source_id, stable_id, chapter_idx)
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

    local cur = Session.current()
    local identity = cur and cur.identity
    if identity and identity.source_id == source_id and identity.stable_id == stable_id then
        local annotations = cur.ui and cur.ui.annotation and cur.ui.annotation.annotations
        for _, item in ipairs(annotations or {}) do push(item) end
        if #items > 0 then return items end
    end

    if type(source_id) ~= "string" or type(stable_id) ~= "string" then
        return items
    end
    local ok, NoteDB = pcall(require, "utils.db.note")
    if not ok or not NoteDB then return items end
    local idx = tonumber(chapter_idx) or 0
    local row = NoteDB.get(source_id, stable_id, idx)
    local payload = row and row.payload
    if type(payload) ~= "string" or payload == "" then return items end
    local jok, JSON = pcall(require, "json")
    if not jok then return items end
    local dok, data = pcall(JSON.decode, payload)
    if not dok or type(data) ~= "table" then return items end
    for _, item in ipairs(data) do push(item) end
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
    local picked = items[(tonumber(index) or 0) % #items + 1]
    local parts = {}
    local chapter = picked.chapter
        or (type(picked.chapters) == "table" and picked.chapters[1])
    if type(chapter) == "string" and chapter ~= "" then
        local U = require("lockscreen.components.util")
        local cleaned = U.cleanChapterTitle(chapter)
        parts[#parts + 1] = cleaned ~= "" and cleaned or chapter
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

return Highlights
