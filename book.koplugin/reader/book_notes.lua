--[[--
连续章节模式的全书笔记列表。

每章是独立文档，KOReader 原生书签列表只看得到当前章。这里把 notes 表里
同一本书所有章节的快照（当前章用阅读器内存注解）按章节汇总成一个列表，
点一条跳过去：本章直接定位，其他章切章后定位。原生列表保留在标题栏左键，
用于编辑 / 删除本章条目。

侧栏的书签页和书摘页都走 onShowBookmark，事先写好 bookmark.match_table。
这里按同一套类型留下对应条目，否则两个页签弹出的是同一份未过滤列表。
带 search_str 的搜索仍交给原生列表（它在当前章里就地筛）。

@module koplugin.book.reader.book_notes
--]]

require("l10n").apply()

local NoteDB = require("book.note_db")
local Normalize = require("book.note.normalize")
local _ = require("gettext")
local T = require("ffi/util").template

local BookNotes = {}

---@class BookNoteEntry
---@field chapter_idx integer 0 表示没有章节归属
---@field chapter string
---@field text string
---@field note string|nil
---@field xpointer string|nil 章节文档内位置；远端条目未在本机开过章时为空

---@param item table KOReader 注解
---@return string|nil
local function xpointerOf(item)
    local loc = item.pos0 or item.page
    return type(loc) == "string" and loc ~= "" and loc or nil
end

--- 与 ReaderBookmark.getBookmarkType 同一规则。空串当缺省：
--- SQL / JSON 会把 nil 写成 ""，而空串在 Lua 里为真，会把书签判成划线、把划线判成笔记。
---@param item table
---@return string
local function annotationType(item)
    local drawer = item.drawer
    if type(drawer) ~= "string" or drawer == "" then return "bookmark" end
    local note = item.note
    if type(note) == "string" and note ~= "" then return "note" end
    return "highlight"
end

--- 汇总全书注解，按章节序排列；章内保持快照原顺序。
--- match 即 ReaderBookmark.match_table：缺省不过滤；给出时只留 type 命中的条目。
---@param source_id string
---@param stable_id string
---@param current_idx integer 当前章（用 live 代替库里的旧快照）
---@param live table[] 当前章阅读器内存注解
---@param titles table<integer, string> 章节序 → 标题
---@param match table|nil
---@return BookNoteEntry[]
function BookNotes.collect(source_id, stable_id, current_idx, live, titles, match)
    local chapters = { [current_idx] = live }
    for _idx, row in ipairs(NoteDB.all(source_id, stable_id)) do
        if row.chapter_idx ~= current_idx then
            chapters[row.chapter_idx] = Normalize.decode(row.payload) or {}
        end
    end
    local order = {}
    for idx in pairs(chapters) do order[#order + 1] = idx end
    table.sort(order)
    local out = {}
    for _idx, idx in ipairs(order) do
        for _idx, item in ipairs(chapters[idx]) do
            local text = type(item) == "table" and item.text
            if type(text) == "string" and text ~= "" and (not match or match[annotationType(item)]) then
                out[#out + 1] = {
                    chapter_idx = idx,
                    chapter = titles[idx] or item.chapter or "",
                    text = text,
                    note = type(item.note) == "string" and item.note ~= "" and item.note or nil,
                    xpointer = xpointerOf(item),
                }
            end
        end
    end
    return out
end

--- 跳到条目位置：本章直接定位，其他章经会话切章后定位。
---@param ui table
---@param entry BookNoteEntry
---@param current_idx integer
local function jump(ui, entry, current_idx)
    if entry.chapter_idx == current_idx then
        if entry.xpointer then
            ui:handleEvent(require("ui/event"):new("GotoXPointer", entry.xpointer, entry.xpointer))
        end
        return
    end
    if entry.chapter_idx > 0 then
        require("reader.session").gotoChapter(entry.chapter_idx, { xpointer = entry.xpointer })
    end
end

--- 打开全书笔记列表。
---@param ui table ReaderUI
---@param snapshot ReaderSessionSnapshot 连续章节会话
---@param native fun() KOReader 原生书签列表（本章）
function BookNotes.show(ui, snapshot, native)
    local identity = snapshot.identity
    local current_idx = identity.chapter_idx
    local titles = {}
    for _idx, entry in ipairs(snapshot.chapter and snapshot.chapter.toc or {}) do
        local idx = tonumber(entry.idx)
        if idx then titles[idx] = entry.title end
    end
    local live = ui.annotation and ui.annotation.annotations or {}
    local match = ui.bookmark and ui.bookmark.match_table
    local entries = BookNotes.collect(identity.source_id, identity.stable_id, current_idx, live, titles, match)

    local items = {}
    for _idx, entry in ipairs(entries) do
        items[#items + 1] = {
            text = entry.text,
            icon = entry.note and "edit_note" or nil,
            mandatory = entry.chapter,
            callback = function() jump(ui, entry, current_idx) end,
        }
    end
    local title
    if match and match.bookmark and not match.highlight and not match.note then
        title = T(_("全书书签（%1）"), #items)
    elseif match and not match.bookmark and (match.highlight or match.note) then
        title = T(_("全书书摘（%1）"), #items)
    else
        title = T(_("全书笔记（%1）"), #items)
    end
    local list
    list = require("ui.themes.widgets.list"):new{
        title = title,
        items = items,
        left_icon = "menu",
        left_callback = function()
            list:close()
            native()
        end,
    }
    list:show()
end

--- 连续章节模式下接管 ReaderBookmark:onShowBookmark（菜单、手势、快捷面板都走它）。
---@param ui table ReaderUI
function BookNotes.install(ui)
    local bookmark = ui and ui.bookmark
    if not bookmark or bookmark._book_notes_wrapped then return end
    bookmark._book_notes_wrapped = true
    local original = bookmark.onShowBookmark
    bookmark.onShowBookmark = require("ui.guard").wrap("show bookmark", function(self)
        local snapshot = require("reader.session").current()
        if not (snapshot and snapshot.chapter and snapshot.identity.chapter_idx) then
            return original(self)
        end
        -- 搜索在原生列表里就地筛当前章；全书列表没有搜索框，接过来会把查询丢掉。
        if self.match_table and self.match_table.search_str then
            return original(self)
        end
        BookNotes.show(ui, snapshot, function() original(self) end)
        return true
    end)
end

return BookNotes
