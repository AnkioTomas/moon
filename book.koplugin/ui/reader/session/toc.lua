--[[--
统一目录与当前章：整书文档 TOC + 连续章节书目 TOC。

@module koplugin.book.ui.reader.session.toc
--]]

local Mode = require("ui.reader.session.mode")
local Chapter = require("ui.reader.session.chapter")
local DocumentToc = require("ui.reader.session.document_toc")

local Toc = {}

---@param session ReaderSessionSnapshot|nil
---@return BookChapter[]|nil
function Toc.list(session)
    if not session then return nil end
    if Mode.isChapter(session.identity) then
        return Chapter.toc(session)
    end
    return DocumentToc.list(session.ui)
end

---@param session ReaderSessionSnapshot|nil
---@return { idx: integer, title: string }|nil
function Toc.current(session)
    if not session then return nil end
    if Mode.isChapter(session.identity) then
        local idx = session.identity and session.identity.chapter_idx
        idx = idx and tonumber(idx)
        if not idx then return nil end
        local title = Chapter.chapterTitle(session)
        if not title then return nil end
        return { idx = idx, title = title }
    end
    return DocumentToc.current(session.ui)
end

---@param session ReaderSessionSnapshot|nil
---@return number|nil
function Toc.chapterFraction(session)
    if not session then return nil end
    if Mode.isChapter(session.identity) then
        return tonumber(session.doc_fraction)
    end
    return DocumentToc.chapterFraction(session.ui)
end

---@param session ReaderSessionSnapshot|nil
---@param idx integer
---@param opts { within: number|nil, direction: "prev"|"next"|nil }|nil
---@return boolean
function Toc.gotoChapter(session, idx, opts)
    if not session then return false end
    if Mode.isChapter(session.identity) then
        return Chapter.gotoChapter(session, idx, opts)
    end
    return DocumentToc.gotoIndex(session.ui, idx, opts)
end

---@param session ReaderSessionSnapshot|nil
---@param delta integer
---@return boolean
function Toc.onBoundary(session, delta)
    if not session then return false end
    if Mode.isChapter(session.identity) then
        return Chapter.onChapterBoundary(session, delta)
    end
    return DocumentToc.onBoundary(session.ui, delta)
end

return Toc
