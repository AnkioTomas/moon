--[[--
连续章节模式的全书笔记列表。

每章是独立文档，KOReader 原生书签列表只看得到当前章。这里把 notes 表里
同一本书所有章节的快照（当前章用阅读器内存注解）按章节汇总成一个列表，
点一条跳过去：本章直接定位，其他章切章后定位。原生列表保留在标题栏左键，
用于编辑 / 删除本章条目。

@module koplugin.book.ui.reader.book_notes
--]]

require("l10n").apply()

local JSON = require("json")
local NoteDB = require("db.note")
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

---@param payload string|nil
---@return table[]
local function decode(payload)
    local ok, value = pcall(JSON.decode, payload or "[]")
    return ok and (Normalize.unpack(value)) or {}
end

---@param item table KOReader 注解
---@return string|nil
local function xpointerOf(item)
    local loc = item.pos0 or item.page
    return type(loc) == "string" and loc ~= "" and loc or nil
end

--- 汇总全书注解，按章节序排列；章内保持快照原顺序。
---@param source_id string
---@param stable_id string
---@param current_idx integer 当前章（用 live 代替库里的旧快照）
---@param live table[] 当前章阅读器内存注解
---@param titles table<integer, string> 章节序 → 标题
---@return BookNoteEntry[]
function BookNotes.collect(source_id, stable_id, current_idx, live, titles)
    local chapters = { [current_idx] = live }
    for _, row in ipairs(NoteDB.all(source_id)) do
        if row.stable_id == stable_id and row.chapter_idx ~= current_idx then
            chapters[row.chapter_idx] = decode(row.payload)
        end
    end
    local order = {}
    for idx in pairs(chapters) do order[#order + 1] = idx end
    table.sort(order)
    local out = {}
    for _, idx in ipairs(order) do
        for _, item in ipairs(chapters[idx]) do
            local text = type(item) == "table" and item.text
            if type(text) == "string" and text ~= "" then
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
        require("ui.reader.session").gotoChapter(entry.chapter_idx, { xpointer = entry.xpointer })
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
    for _, entry in ipairs(snapshot.chapter and snapshot.chapter.toc or {}) do
        local idx = tonumber(entry.idx)
        if idx then titles[idx] = entry.title end
    end
    local live = ui.annotation and ui.annotation.annotations or {}
    local entries = BookNotes.collect(identity.source_id, identity.stable_id, current_idx, live, titles)

    local UIManager = require("ui/uimanager")
    local Menu = require("ui/widget/menu")
    local menu
    local item_table = {}
    for _, entry in ipairs(entries) do
        item_table[#item_table + 1] = {
            text = entry.note and (entry.text .. "\n✎ " .. entry.note) or entry.text,
            mandatory = entry.chapter,
            bold = entry.chapter_idx == current_idx,
            callback = function() jump(ui, entry, current_idx) end,
        }
    end
    menu = Menu:new{
        title = T(_("全书笔记（%1）"), #item_table),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        items_max_lines = 3,
    }
    function menu:onLeftButtonTap()
        UIManager:close(menu)
        native()
    end
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
end

--- 连续章节模式下接管 ReaderBookmark:onShowBookmark（菜单、手势、快捷面板都走它）。
---@param ui table ReaderUI
function BookNotes.install(ui)
    local bookmark = ui and ui.bookmark
    if not bookmark or bookmark._book_notes_wrapped then return end
    bookmark._book_notes_wrapped = true
    local original = bookmark.onShowBookmark
    bookmark.onShowBookmark = function(self)
        local snapshot = require("ui.reader.session").current()
        if not (snapshot and snapshot.chapter and snapshot.identity.chapter_idx) then
            return original(self)
        end
        BookNotes.show(ui, snapshot, function() original(self) end)
        return true
    end
end

return BookNotes
