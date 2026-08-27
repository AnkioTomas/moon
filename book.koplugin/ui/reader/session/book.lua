--[[--
整书阅读编排：单文档快照，无跨文档章节状态。

@module koplugin.book.ui.reader.session.book
--]]

local Chapter = require("ui.reader.session.chapter")
local Snapshot = require("ui.reader.session.snapshot")

local Book = {}

---@param plugin table
---@param session ReaderSessionSnapshot
function Book.onReaderReady(_plugin, session)
    Chapter.clearActiveChapter(session)
    Snapshot.refresh(session)
end

return Book
