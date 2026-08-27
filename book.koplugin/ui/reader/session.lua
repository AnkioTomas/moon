--[[--
书籍级阅读会话。

ReaderSessionSnapshot 随单个文档 ReaderReady/CloseDocument 创建和销毁；
ReaderChapterSession 跨 switchDocument 保留到真正关书。物理路径解析出的 BookIdentity
是身份真相，目录、下载和入库由属主源负责，本模块只编排阅读生命周期与切章。

@module koplugin.book.ui.reader.session
--]]

local Store = require("book.store")
local _ = require("gettext")

local Session = {}

local PREFETCH_AHEAD = 3

---@class ReaderSessionSnapshot
---@field ui table 当前 ReaderUI
---@field identity BookIdentity 当前物理文档身份
---@field page integer 当前文档页码
---@field total_pages integer 当前文档页数
---@field doc_fraction number 当前文档阅读比例（0..1）
---@field fraction number 全书阅读比例（0..1）
---@field chapter_fraction number|nil 当前章节阅读比例（0..1）
---@field percent number 全书阅读百分比（0..100）
---@field chapter ReaderChapterSession|nil 当前文档的章节上下文

---@class ReaderChapterSession
---@field identity BookIdentity 书籍身份与属主源
---@field toc BookChapter[] 从 toc 表恢复的目录快照
---@field transition { cancel: fun() }|{ path: string, within: number|nil, direction: "prev"|"next"|nil }|nil 在途任务或待打开目标

---@type ReaderSessionSnapshot|nil
local current_session
---@type ReaderChapterSession|nil
local chapter_session
---@type { cancel: fun() }|nil
local prefetch_job
---@type string|nil
local speed_key
---@type { total_seconds: number, pages: number }|nil
local speed_summary

--- 取消在途预取任务。
local function cancelPrefetch()
    local job = prefetch_job
    prefetch_job = nil
    if job and job.cancel then job.cancel() end
end

--- 清除当前 ReaderUI 的章节导航状态。
local function clearActiveChapter()
    local chapter = chapter_session
    chapter_session = nil
    cancelPrefetch()
    if current_session then current_session.chapter = nil end
    local transition = chapter and chapter.transition
    if transition and transition.cancel then transition.cancel() end
end

--- 返回绑定当前物理文档的章节状态。
---@return ReaderChapterSession|nil
local function activeChapter()
    return current_session and current_session.chapter
end

--- 当前阅读快照；调用方只读，不得修改其字段。
---@return ReaderSessionSnapshot|nil
function Session.current()
    return current_session
end

--- 当前活跃章节书的目录；整本书或目录未落库时返回 nil。
---@return BookChapter[]|nil
function Session.toc()
    local chapter = activeChapter()
    return chapter and chapter.toc or nil
end

--- 在目录中按章序号查找条目（支持 toc[idx] 与 entry.idx 两种布局）。
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

--- 目录条目标题。
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

--- 当前章节标题：抹平按章书与整本书差异，统一读 session 目录里的 title。
---@param snapshot ReaderSessionSnapshot|nil 缺省当前会话
---@return string|nil
function Session.chapterTitle(snapshot)
    snapshot = snapshot or current_session
    if not snapshot then
        return nil
    end
    local id = snapshot.identity
    local toc = snapshot.chapter and snapshot.chapter.toc
    if not toc then
        local chapter = activeChapter()
        toc = chapter and chapter.toc
    end
    if toc and id and id.chapter_idx then
        return tocTitle(tocEntry(toc, id.chapter_idx))
    end
    return nil
end

--- 当前会话是否仍绑定指定身份；用于异步回调丢弃旧文档结果。
---@param identity BookIdentity|nil
---@return boolean
function Session.isCurrent(identity)
    local current = current_session
    local current_id = current and current.identity
    return current_id ~= nil and identity ~= nil
        and current_id.source_id == identity.source_id
        and current_id.stable_id == identity.stable_id
        and current_id.chapter_idx == identity.chapter_idx
end

--- 当前会话的进度位置快照。
---@return ProgressPosition|nil
function Session.position()
    local current = current_session
    if not current then return nil end
    return require("book.progress").position(current)
end

--- 读取当前书的阅读统计摘要，按身份缓存。
---@param identity BookIdentity|nil
---@return { total_seconds: number, pages: number }|nil
local function readingSummary(identity)
    if type(identity) ~= "table" or not identity.source_id or not identity.stable_id then
        return nil
    end
    local key = identity.source_id .. "/" .. identity.stable_id
    if speed_key == key then
        return speed_summary
    end
    speed_key = key
    speed_summary = require("utils.db.stats").summaryByBook(identity.source_id, identity.stable_id)
    return speed_summary
end

--- 全书剩余阅读时间估算（秒）；数据不足或已读完返回 nil。
--- 基于 session.fraction（全书比例）与历史阅读时长线性外推。
---@return number|nil
function Session.remainingSeconds()
    local current = current_session
    if not current or type(current.identity) ~= "table" then
        return nil
    end
    local fraction = tonumber(current.fraction)
    if not fraction or fraction <= 0 or fraction >= 1 then
        return nil
    end
    local summary = readingSummary(current.identity)
    if type(summary) ~= "table" then
        return nil
    end
    local total_seconds = tonumber(summary.total_seconds)
    local pages = tonumber(summary.pages)
    if not total_seconds or total_seconds <= 0 or not pages or pages <= 0 then
        return nil
    end
    return math.floor(total_seconds * (1 - fraction) / fraction)
end

--- 根据已确认打开的目标章定位新文档，并清掉切换状态。
---@param chapter ReaderChapterSession
---@param ui table
local function applyChapterTarget(chapter, ui)
    local target = chapter.transition
    chapter.transition = nil
    if target.within == nil and target.direction == nil then return end
    local within, direction = target.within, target.direction

    require("ui/uimanager"):nextTick(function()
        if activeChapter() ~= chapter or ui.document.file ~= target.path then return end
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

--- 章节 ReaderUI 实例只挂一次首边界处理。
---@param ui table ReaderUI
local function wrapBoundary(view, position, atStart)
    local original = view and view.onGotoViewRel
    if not original then return end
    view.onGotoViewRel = function(self, diff)
        if not activeChapter() then return original(self, diff) end
        local before = position(self)
        local result = original(self, diff)
        if diff < 0 and atStart(before, position(self)) then
            self.ui:handleEvent(require("ui/event"):new("StartOfBook"))
        end
        return result
    end
end

local function wrapChapterReaderUi(ui)
    if not ui or ui.name ~= "ReaderUI" or ui._book_chapters_wrapped then return end
    ui._book_chapters_wrapped = true
    local status = ui.status
    if status and status.onEndOfBook and not ui._book_end_of_book_wrapped then
        ui._book_end_of_book_wrapped = true
        local original = status.onEndOfBook
        status.onEndOfBook = function(self)
            if Session.onChapterBoundary(1) then
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

local function validNumber(value, minimum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    if minimum and value < minimum then return nil end
    return value
end

--- 读取 ReaderUI 当前页；读取失败时保留上一份快照，初始值为 0（未知）。
---@param ui table|nil
---@param hint number|string|nil
---@param previous number|nil
---@return number
local function readPage(ui, hint, previous)
    local page = validNumber(hint, 1)
    if not page and ui and type(ui.getCurrentPage) == "function" then
        local ok, value = pcall(ui.getCurrentPage, ui)
        if ok then page = validNumber(value, 1) end
    end
    return page and math.floor(page) or previous or 0
end

--- 读取文档总页数；读取失败时保留上一份快照，初始值为 0（未知）。
---@param ui table|nil
---@param previous number|nil
---@return number
local function readTotalPages(ui, previous)
    local document = ui and ui.document
    if document and type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        value = ok and validNumber(value, 0) or nil
        if value then return math.floor(value) end
    end
    return previous or 0
end

--- 读取当前文档比例；优先使用 XPointer，页码仅作兼容回退。
---@param ui table|nil
---@param page number
---@param total number
---@return number
local function readDocumentFraction(ui, page, total)
    local document = ui and ui.document
    if document and type(document.getXPointer) == "function"
        and type(document.getProportionFromXPointer) == "function" then
        local ok, value = pcall(function()
            return document:getProportionFromXPointer(document:getXPointer())
        end)
        value = ok and validNumber(value, 0) or nil
        if value then return math.min(1, value) end
    end
    if total > 0 and page > 0 then
        return math.max(0, math.min(1, page / total))
    end
    return 0
end

--- 刷新页码、页数和全书百分比快照。
---@param session ReaderSessionSnapshot
---@param page number|nil KOReader 事件给出的页码；缺省时读取 ReaderUI
local function snapshot(session, page)
    local ui = session.ui
    session.page = readPage(ui, page, session.page)
    session.total_pages = readTotalPages(ui, session.total_pages)
    session.doc_fraction = readDocumentFraction(ui, session.page, session.total_pages)
    local position = require("book.progress").position(session)
    session.fraction = position.fraction
    session.chapter_fraction = position.chapter_fraction
    session.percent = position.fraction * 100
end

--- 后台预取当前章之后的章节；切章/关书时取消。
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

--- ReaderReady：按物理路径重建阅读快照并启动统计、进度和阅读 UI。
---@param plugin table Book 插件实例
function Session.onReaderReady(plugin)
    -- KOReader 切文档时不保证先派发 CloseDocument，旧快照必须先作废。
    current_session = nil
    local ui = plugin.ui
    local identity = Store.ensureIdentity(ui.document.file)
    if not identity then
        clearActiveChapter()
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("无法识别此书，请从 Book 桌面打开。"),
            ok_text = _("关闭文档"),
            ok_callback = function() ui:onClose() end,
            cancel_text = _("仍要阅读"),
        })
        return
    end

    current_session = {
        ui = ui,
        identity = identity,
        page = 0,
        total_pages = 0,
        doc_fraction = 0,
        fraction = 0,
        chapter_fraction = nil,
        percent = 0,
    }
    local toc = identity.chapter_idx and Store.toc(identity)
    if toc then
        local transition = chapter_session and chapter_session.transition
        if transition and transition.path == ui.document.file then
            chapter_session.transition = nil
        else
            transition = { path = ui.document.file }
        end
        local nav_target = transition.within ~= nil or transition.direction ~= nil
        clearActiveChapter()
        local chapter = { identity = identity, toc = toc, transition = transition }
        chapter_session = chapter
        current_session.chapter = chapter
        applyChapterTarget(chapter, ui)
        wrapChapterReaderUi(ui)
        snapshot(current_session)
        if not nav_target then
            require("book.progress").applyLocalPending(current_session)
            snapshot(current_session)
        end
        require("book.stats").start(current_session)
        require("ui.reader").attach(plugin)
        require("book.progress").pull(current_session)
        require("book.note").pull(ui, identity)
        schedulePrefetch(chapter)
        return
    else
        clearActiveChapter()
    end

    snapshot(current_session)
    require("book.stats").start(current_session)
    require("ui.reader").attach(plugin)
    require("book.progress").pull(current_session)
    require("book.note").pull(ui, identity)
end

--- 推送当前进度和注解，并向属主源发送生命周期事件。
---@param plugin table
---@param event string
local function syncReading(plugin, event)
    local identity = current_session and current_session.identity
    local source = identity and identity.source
    if source and identity then
        require("book.progress").save(current_session, function(ok)
            if ok and source.syncProgressAsync then
                source:syncProgressAsync({ identity = identity }, function() end)
            end
        end)
        require("book.note").save(plugin.ui, identity, function(ok)
            if ok and source.syncNotesAsync then
                source:syncNotesAsync({ identity = identity }, function() end)
            end
        end)
    end
    require("book.stats").stop(function()
        if source and source.syncStatsAsync then
            source:syncStatsAsync({ dirty_only = true }, function()
                plugin:emitToSource(event, nil, source)
            end)
        elseif source then
            plugin:emitToSource(event, nil, source)
        end
    end)
end

--- CloseDocument：结清阅读状态；切章保留目录，真正关书清除全部章节状态。
---@param plugin table Book 插件实例
function Session.onCloseDocument(plugin)
    syncReading(plugin, "document_close")
    local transition = chapter_session and chapter_session.transition
    if not (transition and transition.path) then
        clearActiveChapter()
        require("book.progress").clearConflicts()
    end
    current_session = nil
end

--- 页码变化：结清上一页统计、刷新快照和阅读 UI，并通知属主源。
--- 分页视图与滚动视图都走同一入口。
---@param plugin table Book 插件实例
---@param page number|nil
function Session.onPageChanged(plugin, page)
    local session = current_session
    if not session then
        require("book.stats").onPage(nil)
        return
    end
    snapshot(session, page)
    require("book.stats").onPage(session)
    require("ui.reader").refresh(plugin)
    local source = session.identity.source
    if source then
        plugin:emitToSource("page_changed", {
            identity = session.identity,
            page = session.page,
            total_pages = session.total_pages,
            percent = session.percent,
        }, source)
    end
end

--- 注解变化：按当前阅读身份保存完整快照。
---@param plugin table Book 插件实例
---@param _items table KOReader 变更描述；完整数据从 annotation.annotations 读取
function Session.onAnnotationsModified(plugin, _items)
    if current_session then
        require("book.note").save(plugin.ui, current_session.identity)
    end
end

--- 休眠前：结清计时并同步当前进度、注解和源事件；会话继续保留。
---@param plugin table Book 插件实例
function Session.onSuspend(plugin)
    if not plugin.ui.document then return end
    syncReading(plugin, "suspend")
end

--- 唤醒后恢复当前阅读会话的统计计时。
---@param plugin table Book 插件实例
function Session.onResume(plugin)
    if plugin.ui.document and current_session then
        require("book.stats").start(current_session)
    end
end

--- 请求属主源打开目标章，并在成功后切换 ReaderUI 文档。
---@param chapter ReaderChapterSession 发起请求时的章节状态，用于丢弃迟到回调
---@param idx integer
---@param opts { within: number|nil, direction: "prev"|"next"|nil }
local function requestChapter(chapter, idx, opts)
    cancelPrefetch()
    local current_idx = current_session.identity.chapter_idx
    local identity = chapter.identity
    chapter.transition = identity.source:openBookAsync(identity, { chapter_idx = idx }, function(path, err)
        chapter.transition = nil
        if not path then
            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                text = err or _("章节打开失败"),
            })
            return
        end

        local within = opts.within
        local direction = within == nil and opts.direction
        if within == nil and direction == nil and idx ~= current_idx then
            direction = idx < current_idx and "prev" or "next"
        end
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

--- 从目录或其他阅读 UI 切换到指定章节。
---@param idx integer 目标章节序号
---@param opts { within: number|nil, direction: "prev"|"next"|nil }|nil
---@return boolean started
function Session.gotoChapter(idx, opts)
    local chapter = activeChapter()
    local current_idx = current_session and current_session.identity.chapter_idx
    if not chapter or chapter.transition or idx < 1 or idx > #chapter.toc then
        return false
    end
    if current_idx and idx == current_idx then
        return false
    end
    requestChapter(chapter, idx, opts or {})
    return true
end

--- 从页首/页尾边界发起相邻章节切换，并立即锁住重复边界事件。
---@param delta integer -1 表示上一章，1 表示下一章
---@return boolean handled
function Session.onChapterBoundary(delta)
    local chapter = activeChapter()
    if not chapter or chapter.transition then
        return false
    end
    local target = current_session.identity.chapter_idx + delta
    if target < 1 or target > #chapter.toc then return false end
    requestChapter(chapter, target, { direction = delta < 0 and "prev" or "next" })
    return true
end

return Session
