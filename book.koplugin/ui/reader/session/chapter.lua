--[[--
连续章节阅读编排：跨 switchDocument 的章节会话。

@module koplugin.book.ui.reader.session.chapter
--]]

local Store = require("book.store")
local Snapshot = require("ui.reader.session.snapshot")
local _ = require("gettext")

---@class ReaderChapterSession
---@field identity BookIdentity 书籍身份与属主源
---@field toc BookChapter[] 从 toc 表恢复的目录快照
---@field transition { cancel: fun() }|{ path: string, within: number|nil, direction: "prev"|"next"|nil }|nil 在途任务或待打开目标

local Chapter = {}

local PREFETCH_AHEAD = 3

---@type ReaderChapterSession|nil
local chapter_session
---@type { cancel: fun() }|nil
local prefetch_job

local function cancelPrefetch()
    local job = prefetch_job
    prefetch_job = nil
    if job and job.cancel then job.cancel() end
end

---@param session ReaderSessionSnapshot|nil
function Chapter.clearActiveChapter(session)
    local chapter = chapter_session
    chapter_session = nil
    cancelPrefetch()
    if session then session.chapter = nil end
    local transition = chapter and chapter.transition
    if transition and transition.cancel then transition.cancel() end
end

---@param session ReaderSessionSnapshot|nil
---@return ReaderChapterSession|nil
function Chapter.activeChapter(session)
    return session and session.chapter
end

---@param session ReaderSessionSnapshot|nil
---@return BookChapter[]|nil
function Chapter.toc(session)
    local chapter = Chapter.activeChapter(session)
    return chapter and chapter.toc or nil
end

---@param toc BookChapter[]|table
---@param chapter_idx number|string|nil
---@return BookChapter|nil
local function tocEntry(toc, chapter_idx)
    local idx = tonumber(chapter_idx)
    if not idx or type(toc) ~= "table" then
        return nil
    end
    local direct = toc[idx]
    if type(direct) == "table" then
        local entry_idx = tonumber(direct.idx)
        if entry_idx == nil or entry_idx == idx then
            return direct
        end
    end
    for _, entry in ipairs(toc) do
        if type(entry) == "table" and tonumber(entry.idx) == idx then
            return entry
        end
    end
    return type(direct) == "table" and direct or nil
end

---@param entry BookChapter|table|nil
---@return string|nil
local function tocTitle(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local title = entry.title or entry.name
    if type(title) ~= "string" then
        return nil
    end
    title = title:match("^%s*(.-)%s*$")
    if title == "" then
        return nil
    end
    return title
end

---@param snapshot ReaderSessionSnapshot|nil
---@return string|nil
function Chapter.chapterTitle(snapshot)
    if not snapshot then
        return nil
    end
    local id = snapshot.identity
    local toc = snapshot.chapter and snapshot.chapter.toc
    if toc and id and id.chapter_idx then
        return tocTitle(tocEntry(toc, id.chapter_idx))
    end
    return nil
end

---@param chapter ReaderChapterSession
---@param ui table
local function applyChapterTarget(chapter, ui)
    local target = chapter.transition
    chapter.transition = nil
    if target.within == nil and target.direction == nil then return end
    local within, direction = target.within, target.direction

    require("ui/uimanager"):nextTick(function()
        if chapter_session ~= chapter or ui.document.file ~= target.path then return end
        local page
        if within ~= nil then
            within = require("types.book_progress").clampFraction(within)
            if ui.document.getXPointerFromProportion then
                local xptr = ui.document:getXPointerFromProportion(within)
                if xptr and ui.rolling then
                    ui.rolling:onGotoXPointer(xptr)
                    return
                elseif xptr and ui.link then
                    ui.link:onGotoXPointer(xptr)
                    return
                end
            end
            if ui.document.getPageCount then
                local total = ui.document:getPageCount() or 1
                page = math.max(1, math.min(total, math.floor(within * total + 0.5)))
            end
        elseif direction == "prev" then
            local total
            if ui.document.getPageCount then
                total = ui.document:getPageCount()
            end
            if total and total > 1 then
                page = total
            end
        elseif direction == "next" then
            page = 1
        end
        if not page then return end
        if ui.link then
            ui.link:addCurrentLocationToStack()
        end
        ui:handleEvent(require("ui/event"):new("GotoPage", page))
    end)
end

---@param view table|nil
---@param position fun(view: table): number
---@param atStart fun(before: number, after: number): boolean
local function wrapBoundary(view, position, atStart)
    local original = view and view.onGotoViewRel
    if not original then return end
    view.onGotoViewRel = function(self, diff)
        if not chapter_session then return original(self, diff) end
        local before = position(self)
        local result = original(self, diff)
        if diff < 0 and atStart(before, position(self)) then
            self.ui:handleEvent(require("ui/event"):new("StartOfBook"))
        end
        return result
    end
end

---@param ui table
local function wrapChapterReaderUi(ui)
    if not ui or ui.name ~= "ReaderUI" or ui._book_chapters_wrapped then return end
    ui._book_chapters_wrapped = true
    local status = ui.status
    if status and status.onEndOfBook and not ui._book_end_of_book_wrapped then
        ui._book_end_of_book_wrapped = true
        local original = status.onEndOfBook
        status.onEndOfBook = function(self)
            if require("ui.reader.session").onChapterBoundary(1) then
                return true
            end
            return original(self)
        end
    end
    wrapBoundary(ui.rolling, function(view)
        if view.view and view.view.view_mode == "scroll" then
            return view.current_pos
        end
        return view.current_page
    end, function(before, after)
        return before == after
    end)
    wrapBoundary(ui.paging, function(view)
        return view.getTopPage and view:getTopPage() or view.current_page
    end, function(before, after)
        return before == 1 and after == before
    end)
end

---@param chapter ReaderChapterSession
local function schedulePrefetch(chapter)
    cancelPrefetch()
    if not chapter or chapter.transition then return end
    local identity = chapter.identity
    local source = identity and identity.source
    local idx = identity and identity.chapter_idx
    if not source or not idx or type(source.prefetchChaptersAsync) ~= "function" then
        return
    end
    prefetch_job = source:prefetchChaptersAsync(identity, chapter.toc, idx, PREFETCH_AHEAD)
end

---@param plugin table
---@param session ReaderSessionSnapshot
---@return boolean nav_target 切章导航目标已指定，跳过 pending 本地进度
function Chapter.onReaderReady(plugin, session)
    local ui = plugin.ui
    local identity = session.identity
    local toc = Store.toc(identity)
    local transition = chapter_session and chapter_session.transition
    if transition and transition.path == ui.document.file then
        chapter_session.transition = nil
    else
        transition = { path = ui.document.file }
    end
    local nav_target = transition.within ~= nil or transition.direction ~= nil
    Chapter.clearActiveChapter(session)
    local chapter = { identity = identity, toc = toc, transition = transition }
    chapter_session = chapter
    session.chapter = chapter
    applyChapterTarget(chapter, ui)
    wrapChapterReaderUi(ui)
    Snapshot.refresh(session)
    if not nav_target then
        require("book.progress").applyLocalPending(session)
        Snapshot.refresh(session)
    end
    return nav_target
end

---@param session ReaderSessionSnapshot
function Chapter.afterBootstrap(session)
    local chapter = Chapter.activeChapter(session)
    if chapter then
        schedulePrefetch(chapter)
    end
end

---@param session ReaderSessionSnapshot|nil
---@return boolean clear_conflicts 是否清除进度冲突记忆
function Chapter.onCloseDocument(session)
    local transition = chapter_session and chapter_session.transition
    if not (transition and transition.path) then
        Chapter.clearActiveChapter(session)
        return true
    end
    return false
end

---@param chapter ReaderChapterSession
---@param idx integer
---@param opts { within: number|nil, direction: "prev"|"next"|nil }
local function requestChapter(chapter, idx, opts)
    cancelPrefetch()
    local identity = chapter.identity
    chapter.transition = identity.source:openBookAsync(identity, { chapter_idx = idx }, function(path, err)
        chapter.transition = nil
        if not path then
            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                text = err or _("章节打开失败"),
            })
            return
        end

        -- 目录跳转不带方向：一律落到章首；只有翻页越界（显式 prev）才回上一章尾部
        local within = opts.within
        local direction = within == nil and (opts.direction or "next") or nil
        chapter.transition = {
            path = path,
            within = within,
            direction = direction,
        }

        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance then
            ReaderUI.instance:switchDocument(path, true)
        else
            require("ui/uimanager"):nextTick(function()
                ReaderUI:showReader(path, nil, true)
            end)
        end
    end)
end

---@param session ReaderSessionSnapshot|nil
---@param idx integer
---@param opts { within: number|nil, direction: "prev"|"next"|nil }|nil
---@return boolean
function Chapter.gotoChapter(session, idx, opts)
    if not session then return false end
    local chapter = Chapter.activeChapter(session)
    local current_idx = session.identity.chapter_idx
    if not chapter or chapter.transition or idx < 1 or idx > #chapter.toc then
        return false
    end
    if current_idx and idx == current_idx then
        return false
    end
    requestChapter(chapter, idx, opts or {})
    return true
end

---@param session ReaderSessionSnapshot|nil
---@param delta integer
---@return boolean
function Chapter.onChapterBoundary(session, delta)
    if not session then return false end
    local chapter = Chapter.activeChapter(session)
    if not chapter or chapter.transition then
        return false
    end
    local target = session.identity.chapter_idx + delta
    if target < 1 or target > #chapter.toc then return false end
    requestChapter(chapter, target, { direction = delta < 0 and "prev" or "next" })
    return true
end

return Chapter
