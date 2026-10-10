--[[--
统一目录与当前章：整书文档 TOC + 连续章节书目 TOC。

@module koplugin.book.reader.session.toc
--]]

local Chapter = require("reader.session.chapter")
local DocumentToc = require("reader.session.document_toc")

---@class ReaderSessionToc
local Toc = {}

---@param session ReaderSessionSnapshot|nil
---@return BookChapter[]|nil
function Toc.list(session)
    if not session then return nil end
    if session.identity.chapter_idx ~= nil then
        return Chapter.toc(session)
    end
    return DocumentToc.list(session.ui)
end

---@param session ReaderSessionSnapshot|nil
---@return { idx: integer, title: string }|nil
function Toc.current(session)
    if not session then return nil end
    if session.identity.chapter_idx ~= nil then
        local idx = tonumber(session.identity.chapter_idx)
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
    if session.identity.chapter_idx ~= nil then
        return tonumber(session.doc_fraction)
    end
    return DocumentToc.chapterFraction(session.ui)
end

return Toc
