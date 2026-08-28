--[[--
书籍级阅读会话门面。

ReaderSessionSnapshot 随单个文档 ReaderReady/CloseDocument 创建和销毁；
ReaderChapterSession 跨 switchDocument 保留到真正关书。物理路径解析出的 BookIdentity
是身份真相，目录、下载和入库由属主源负责，本模块只编排阅读生命周期与切章。

@module koplugin.book.ui.reader.session
--]]

local Store = require("book.store")
local Mode = require("ui.reader.session.mode")
local Snapshot = require("ui.reader.session.snapshot")
local BookMode = require("ui.reader.session.book")
local ChapterMode = require("ui.reader.session.chapter")
local Toc = require("ui.reader.session.toc")
local _ = require("gettext")

local Session = {}

local handlers = {
    book = BookMode,
    chapter = ChapterMode,
}

---@type ReaderSessionSnapshot|nil
local current_session

---@param plugin table
---@param session ReaderSessionSnapshot
---@param skip_pull boolean|nil 连续章节切章导航：跳过云端进度拉取与注解拉取
local function bootstrapReading(plugin, session, skip_pull)
    require("book.stats").start(session)
    require("ui.reader").attach(plugin)
    -- 首绘前同步写入注解：晚一个 tick 云端划线就要等下次刷新才出现。切章同样要重来，
    -- 因为注解按 chapter_idx 分片。
    require("book.note").applyLocal(plugin.ui, session.identity)
    if skip_pull then return end
    require("book.progress").pull(session)
    require("book.note").pull(plugin.ui, session.identity)
end

--- 当前阅读快照；调用方只读，不得修改其字段。
---@return ReaderSessionSnapshot|nil
function Session.current()
    return current_session
end

--- 当前是否为连续章节阅读模式。
---@param identity BookIdentity|nil 缺省当前会话身份
---@return boolean
function Session.isChapterMode(identity)
    if identity == nil and current_session then
        identity = current_session.identity
    end
    return Mode.isChapter(identity)
end

--- 当前活跃书籍目录；整书来自 KOReader 文档 TOC，连续章节来自书目 toc 表。
---@return BookChapter[]|nil
function Session.toc()
    return Toc.list(current_session)
end

--- 当前目录章序号；两种模式在 toc 可用时均有效。
---@param snapshot ReaderSessionSnapshot|nil 缺省当前会话
---@return integer|nil
function Session.chapterIndex(snapshot)
    snapshot = snapshot or current_session
    local current = Toc.current(snapshot)
    return current and current.idx or nil
end

--- 当前章节标题；两种模式在 toc 可用时均有效。
---@param snapshot ReaderSessionSnapshot|nil 缺省当前会话
---@return string|nil
function Session.chapterTitle(snapshot)
    snapshot = snapshot or current_session
    local current = Toc.current(snapshot)
    return current and current.title or nil
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

--- 全书剩余阅读时间估算（秒）；数据不足或已读完返回 nil。
---@return number|nil
function Session.remainingSeconds()
    return Snapshot.remainingSeconds(current_session)
end

--- ReaderReady：按物理路径重建阅读快照并启动统计、进度和阅读 UI。
---@param plugin table Book 插件实例
function Session.onReaderReady(plugin)
    current_session = nil
    local ui = plugin.ui
    local identity = Store.ensureIdentity(ui.document.file)
    if not identity then
        ChapterMode.clearActiveChapter(nil)
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

    current_session = Snapshot.new(ui, identity)
    local mode = Mode.resolve(identity)
    local skip_pull = handlers[mode].onReaderReady(plugin, current_session)
    bootstrapReading(plugin, current_session, skip_pull)
    if mode == "chapter" then
        ChapterMode.afterBootstrap(current_session)
    end
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
    if current_session and plugin.ui then
        require("book.reader_prefs").captureAndSave(plugin.ui, current_session.identity)
    end
    syncReading(plugin, "document_close")
    if ChapterMode.onCloseDocument(current_session) then
        require("book.progress").clearConflicts()
    end
    current_session = nil
end

--- 页码变化：结清上一页统计、刷新快照和阅读 UI，并通知属主源。
---@param plugin table Book 插件实例
---@param page number|nil
function Session.onPageChanged(plugin, page)
    local session = current_session
    if not session then
        require("book.stats").onPage(nil)
        return
    end
    Snapshot.refresh(session, page)
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
    if current_session then
        require("book.reader_prefs").captureAndSave(plugin.ui, current_session.identity)
    end
    syncReading(plugin, "suspend")
end

--- 唤醒后恢复当前阅读会话的统计计时。
---@param plugin table Book 插件实例
function Session.onResume(plugin)
    if plugin.ui.document and current_session then
        require("book.stats").start(current_session)
    end
end

--- 从目录或其他阅读 UI 切换到指定章节。
---@param idx integer 目标章节序号
---@param opts { within: number|nil, direction: "prev"|"next"|nil }|nil
---@return boolean started
function Session.gotoChapter(idx, opts)
    return Toc.gotoChapter(current_session, idx, opts)
end

--- 从页首/页尾边界发起相邻章节切换，并立即锁住重复边界事件。
---@param delta integer -1 表示上一章，1 表示下一章
---@return boolean handled
function Session.onChapterBoundary(delta)
    return Toc.onBoundary(current_session, delta)
end

return Session
