--[[--
主体：阅读高亮。

@module koplugin.book.lockscreen.components.highlight
--]]

local Session = require("ui.reader.session")
local Current = require("lockscreen.components.current")
local MoonSettings = require("utils.settings")
local QuotePanel = require("lockscreen.components.quote_panel")
local U = require("lockscreen.components.util")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "highlight",
    label = _("阅读高亮"),
    live = true,
    refresh_on_annotations = true,
    layout = "quote",
}

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

local function collectItems(source_id, stable_id, chapter_idx)
    local items, seen = {}, {}
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
    local annotations = cur and cur.ui and cur.ui.annotation and cur.ui.annotation.annotations
    for _, item in ipairs(annotations or {}) do push(item) end
    if #items > 0 or type(source_id) ~= "string" or type(stable_id) ~= "string" then
        return items
    end

    local ok, NoteDB = pcall(require, "utils.db.note")
    if not ok or not NoteDB then return items end
    local row = NoteDB.get(source_id, stable_id, chapter_idx or 0)
    local payload = row and row.payload
    if type(payload) ~= "string" or payload == "" then return items end
    local jok, JSON = pcall(require, "json")
    if not jok then return items end
    local dok, data = pcall(JSON.decode, payload)
    if not dok or type(data) ~= "table" then return items end
    for _, item in ipairs(data) do push(item) end
    return items
end

--- 轮换一条当前书高亮，并生成章节/页码出处。
---@return string|nil, string|nil
function M.next()
    local cur = Session.current()
    local identity = cur and cur.identity
    local items = collectItems(
        identity and identity.source_id,
        identity and identity.stable_id,
        identity and identity.chapter_idx
    )
    if #items == 0 then
        local book = Current.book()
        if book then items = collectItems(book.source_id, book.stable_id, book.chapter_idx) end
    end
    if #items == 0 then return nil end

    local settings = MoonSettings.get()
    local index = (tonumber(settings.lock_screen_quote_index) or 0) % #items + 1
    settings.lock_screen_quote_index = index
    MoonSettings.save()
    local picked = items[index]
    local parts = {}
    local chapter = picked.chapter
        or (type(picked.chapters) == "table" and picked.chapters[1])
    if type(chapter) == "string" and chapter ~= "" then
        local cleaned = U.cleanChapterTitle(chapter)
        parts[#parts + 1] = cleaned ~= "" and cleaned or chapter
    end
    local page = tonumber(picked.pageno) or tonumber(picked.page)
    if page and page > 0 then parts[#parts + 1] = T(_("第 %1 页"), page) end
    return picked.text, #parts > 0 and table.concat(parts, " · ") or nil
end

-- quote 布局由 compose 传入位置和宽窄，组件只负责取得下一条高亮。
--- 没有高亮时使用公共默认句子，保证锁屏仍有可读内容。
---@param position string
---@param wide boolean
---@return table[]
function M.blocks(position, wide)
    local text, source = M.next()
    if not text then
        return QuotePanel.blocks(U.FALLBACK_MESSAGE, _("默认句子"), position, wide)
    end
    return QuotePanel.blocks(text, source or _("来自当前书籍高亮"), position, wide)
end

return M
