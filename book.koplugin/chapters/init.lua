--[[--
按章阅读公共层：标准正文 → HTML 落盘 + 换章 + 预取。

online / article Source 通过 getTocAsync + fetchChapterContentAsync 提供正文。

@module koplugin.book.chapters
--]]

local Session = require("chapters.session")
local Materialize = require("chapters.materialize")
local Navigate = require("chapters.navigate")

local Chapters = {}

-- session
Chapters.isActive = Session.isActive
Chapters.chapterCount = Session.chapterCount
Chapters.currentIdx = Session.currentIdx
Chapters.toc = Session.toc
Chapters.ref = Session.ref
Chapters.source = Session.source
Chapters.book = Session.book
Chapters.bind = Session.bind
Chapters.generation = Session.generation
Chapters.beginSwitch = Session.beginSwitch
Chapters.consumeSwitch = Session.consumeSwitch
Chapters.hasPendingSwitch = Session.hasPendingSwitch
Chapters.pendingSwitchPath = Session.pendingSwitchPath
Chapters.clearPendingSwitch = Session.clearPendingSwitch

function Chapters.clear()
    Chapters._open_token = nil
    Materialize.cancelInflight()
    Session.clear()
end

-- materialize
Chapters.loadTocAsync = Materialize.loadTocAsync
Chapters.ensureAsync = Materialize.ensureAsync
Chapters.prefetchAround = Materialize.prefetchAround
Chapters.prepareOpenAsync = Materialize.prepareOpenAsync

-- navigate
Chapters.gotoChapter = Navigate.gotoChapter
Chapters.next = Navigate.next
Chapters.prev = Navigate.prev
Chapters.showTocMenu = Navigate.showTocMenu
Chapters.showInitial = Navigate.showInitial
Chapters.onEndOfBook = Navigate.onEndOfBook
Chapters.onStartOfBook = Navigate.onStartOfBook
Chapters.onReaderReady = Navigate.onReaderReady

--- CloseDocument：切章则跳过 clear；真关书才清会话。
---@param closed_path string|nil
---@return boolean cleared
function Chapters.onCloseDocument(closed_path)
    if Session.consumeSwitch(closed_path) then
        return false
    end
    Chapters.clear()
    return true
end

return Chapters
