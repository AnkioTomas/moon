--[[--
书籍级阅读会话门面。

`on*` 入口与 KOReader 阅读事件同名、同参数（首参为插件实例），main.lua 直接挂到插件上。

ReaderSessionSnapshot 随单个文档 ReaderReady/CloseDocument 创建和销毁；
ReaderChapterSession 跨 switchDocument 保留到真正关书。物理路径解析出的 BookIdentity
是身份真相，目录、下载和入库由属主源负责，本模块只编排阅读生命周期与切章。

关书与休眠对 progress / notes / stats 一律只推不拉；切章带 skip_pull。
已读：fraction>=1 或 EndOfBook 标记；可选 99% 自动标记。源事件发给 identity.source，不回落 current。

@module koplugin.book.reader.session
--]]

local Store = require("book.store")
local Snapshot = require("reader.session.snapshot")
local ChapterMode = require("reader.session.chapter")
local Toc = require("reader.session.toc")
local Guard = require("ui.guard")
local _ = require("gettext")

---@class BookReaderSession
---@field _snapshot ReaderSessionSnapshot|nil
local Session = {
    ---@type ReaderSessionSnapshot|nil
    _snapshot = nil,
    --- ReaderReady 超过这个毫秒数按 WARN 记分段耗时
    SLOW_READY_MS = 3000,
}

--- 月读是否认这份文档：Store.identityFor 能解析，且是章节文件或书架成员。
--- deleted=1 是书架已移除的成员，交回原生。
---@param snapshot ReaderSessionSnapshot|nil
---@return boolean
local function moonRecognizes(snapshot)
    if not snapshot or not snapshot.identity then return false end
    local file = snapshot.ui and snapshot.ui.document and snapshot.ui.document.file
    if not Store.identityFor(file) then return false end
    local id = snapshot.identity
    if id.chapter_idx ~= nil then return true end
    -- deleted=1 是 touch 非成员；缺省 / 0 = 书架上的书
    return id.book ~= nil and tonumber(id.book.deleted) ~= 1
end

--- 按全书进度收敛已读状态：100% 是事实，99% 仅是用户可选便利规则。
---@param session ReaderSessionSnapshot|nil
---@param complete boolean|nil EndOfBook 的完成兜底
local function updateReadState(session, complete)
    if not session or not session.identity then return end
    local book = session.identity.book
    local read_state = tonumber(book and book.read_state) or 0
    local finished = complete == true or (tonumber(session.fraction) or 0) >= 1
    local BookDB = require("book.books_db")
    local ok, kind
    -- 写库失败或没有 book 缓存可回写时，同一会话不再每次翻页重试。
    local tried = session.read_marks or {}
    session.read_marks = tried
    if finished and read_state ~= 1 and not tried.complete then
        kind = "complete"
        ok = BookDB.markReadComplete(session.identity.source_id, session.identity.stable_id)
    elseif not finished and session.percent >= 99 and read_state == 0 and not tried.auto
        and require("utils.settings").get("reader").auto_mark_read_at_99 == true then
        kind = "auto"
        ok = BookDB.markReadAutomatically(session.identity.source_id, session.identity.stable_id)
    end
    if kind and not (ok and book) then tried[kind] = true end
    if ok and book then book.read_state = 1 end
end

--- 安装本插件的书籍结束处理。
--- 只接管 Store.identityFor 认得出的书（章节文件 / 书架成员）；库外顺手登记的不算，交回原生。
---@param plugin table
---@param ui table
local function installEndOfBookHandler(plugin, ui)
    local status = ui and ui.status
    if not status or type(status.onEndOfBook) ~= "function"
        or ui._book_end_of_book_handler then
        return
    end
    ui._book_end_of_book_handler = true
    local original = status.onEndOfBook
    status.onEndOfBook = Guard.wrap("onEndOfBook", function(self, ...)
        local snapshot = Session._snapshot
        if ChapterMode.onChapterBoundary(snapshot, 1) then
            return true
        end
        if moonRecognizes(snapshot) then
            updateReadState(snapshot, true)
            require("reader.end_dialog").show(plugin, snapshot.identity)
            return true
        end
        if snapshot then updateReadState(snapshot, true) end
        return original(self, ...)
    end)
end

---@param plugin table
---@param session ReaderSessionSnapshot
---@param skip_pull boolean|nil 连续章节切章导航：跳过云端进度拉取与注解拉取
local function bootstrapReading(plugin, session, skip_pull)
    require("reader.session.stats").start(session)
    require("reader.page").onCreate(plugin)
    -- 首绘前同步写入注解：晚一个 tick 云端划线就要等下次刷新才出现。切章同样要重来，
    -- 因为注解按 chapter_idx 分片。
    require("reader.session.note").applyLocal(plugin.ui, session.identity)
    if skip_pull then return end
    require("reader.session.progress").pull(session)
    require("reader.session.note").pull(plugin.ui, session.identity)
end

--- 整书用已打开的文档补本地封面：云端没封面的书下载后靠它显示（书架/详情/锁屏认这个文件）。
--- 放到下一拍不拖首绘；已有封面直接跳过，文档已换掉就放弃。
---@param ui table
---@param identity BookIdentity
local function ensureCover(ui, identity)
    local doc = ui.document
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("ensure cover", function()
        if ui.document ~= doc then return end
        local Paths = require("utils.paths")
        Paths.ensureLayout(identity.source_id)
        require("book.cover").save(doc, Paths.coverPath(identity.stable_id, identity.source_id))
    end))
end

--- 当前阅读快照；调用方只读，不得修改其字段。
---@return ReaderSessionSnapshot|nil
function Session.current()
    return Session._snapshot
end

--- 当前是否为连续章节阅读模式（身份带章序号即章节文件）。
---@return boolean
function Session.isChapterMode()
    local snapshot = Session._snapshot
    return snapshot ~= nil and snapshot.identity.chapter_idx ~= nil
end

--- 当前活跃书籍目录；整书来自 KOReader 文档 TOC，连续章节来自 books.toc。
---@return BookChapter[]|nil
function Session.toc()
    return Toc.list(Session._snapshot)
end

--- 当前目录章序号；两种模式在 toc 可用时均有效。
---@param snapshot ReaderSessionSnapshot|nil 缺省当前会话
---@return integer|nil
function Session.chapterIndex(snapshot)
    snapshot = snapshot or Session._snapshot
    local current = Toc.current(snapshot)
    return current and current.idx or nil
end

--- 当前章节标题；两种模式在 toc 可用时均有效。
---@param snapshot ReaderSessionSnapshot|nil 缺省当前会话
---@return string|nil
function Session.chapterTitle(snapshot)
    snapshot = snapshot or Session._snapshot
    local current = Toc.current(snapshot)
    return current and current.title or nil
end

--- 当前页在本章的序号与本章页数；两种模式均有效，不在任何章节内返回 nil。
---@param snapshot ReaderSessionSnapshot|nil 缺省当前会话
---@return integer|nil page
---@return integer|nil count
function Session.chapterPages(snapshot)
    return Toc.chapterPages(snapshot or Session._snapshot)
end

--- 全书页码（按章打开时用目录字数估算；估不出则退回文档页码）。顶栏 / 侧栏 / 锁屏共用。
---@param snapshot ReaderSessionSnapshot|nil 缺省当前会话
---@return integer page
---@return integer total
function Session.bookPages(snapshot)
    snapshot = snapshot or Session._snapshot
    if not snapshot then return 0, 0 end
    local page = tonumber(snapshot.page) or 0
    local total = tonumber(snapshot.total_pages) or 0
    if snapshot.identity and snapshot.identity.chapter_idx ~= nil then
        local p, t = require("reader.session.pages").estimate(
            Toc.list(snapshot), snapshot.identity.chapter_idx, page, total)
        if p then return p, t end
    end
    return page, total
end

--- 全书剩余阅读时间估算（秒）；数据不足或已读完返回 nil。
---@return number|nil
function Session.remainingSeconds()
    return Snapshot.remainingSeconds(Session._snapshot)
end

--- 按章打开时 sidecar / 文档属性用书名，不用章文件 <title>（旧缓存仍是章名）。
---@param doc_settings table
---@param document table
local function applyChapterBookTitle(doc_settings, document)
    local file = document and document.file
    if type(file) ~= "string" or file == "" then return end
    local identity = Store.identityFor(file)
    local title = identity and identity.chapter_idx and identity.book and identity.book.title
    if type(title) ~= "string" or title == "" then return end
    local props = doc_settings:readSetting("doc_props") or {}
    if props.title == title and props.display_title == title then return end
    props.title = title
    props.display_title = title
    doc_settings:saveSetting("doc_props", props)
    if type(document.doc_props) == "table" then
        document.doc_props.title = title
        document.doc_props.display_title = title
    end
end

--- DocSettingsLoad：读 sidecar 前写入全书排版偏好与状态栏偏好，由原生模块加载。
---@param _plugin table Book 插件实例
---@param doc_settings table
---@param document table
function Session.onDocSettingsLoad(_plugin, doc_settings, document)
    require("reader.prefs").inject(doc_settings, document)
    require("utils.extension").emit("reader.doc_settings", doc_settings, document)
    applyChapterBookTitle(doc_settings, document)
end

--- KOReader 2026.07 书籍元数据归档的坏状态：选归档目录的回调 path 为 nil 时 saveSetting 把
--- document_metadata_arc_folder 删了，「关书时归档」开关却还开着；此后每次关书 saveSettingsArcFile
--- 对 nil 路径 LuaSettings:open 必炸，sidecar 落不了盘；菜单里那个开关又因没目录而灰掉，用户无法自救。
--- 没有目录的开关毫无意义，直接关掉。每次开书都查，状态在会话中重新出现也能在下一次关书前修好。
function Session.repairMetadataArc()
    if G_reader_settings:isTrue("document_metadata_arc_on_closing")
        and G_reader_settings:hasNot("document_metadata_arc_folder") then
        require("utils.log").warn("book metadata archive enabled without folder; disabling to keep book closing alive")
        G_reader_settings:delSetting("document_metadata_arc_on_closing")
    end
end

--- ReaderReady：按物理路径重建阅读快照并启动统计、进度和阅读 UI。
---@param plugin table Book 插件实例
function Session.onReaderReady(plugin)
    -- ReaderReady 期间 KOReader 屏蔽全部输入，这里慢几十秒用户就是「点什么都没反应」：分段计时，超阈值 warn。
    local span = require("utils.perf").begin("reader.ready")
    Session.repairMetadataArc()
    Session._snapshot = nil
    local ui = plugin.ui
    local identity = Store.ensureIdentity(ui.document.file)
    if not identity then
        ChapterMode.clearActiveChapter(nil)
        -- 库外的书月读不管：不建会话、不提示，交给原生阅读
        if not require("utils.paths").isMoonPath(ui.document.file) then return end
        require("ui.themes.widgets.confirm"):new{
            text = _("无法识别此书，请从月读打开。"),
            ok_text = _("关闭文档"),
            ok_callback = function() ui:onClose() end,
            cancel_text = _("仍要阅读"),
        }:show()
        return
    end
    span:lap("identity")
    Session._snapshot = Snapshot.new(ui, identity)
    installEndOfBookHandler(plugin, ui)
    local chapter_mode = identity.chapter_idx ~= nil
    local skip_pull
    if chapter_mode then
        skip_pull = ChapterMode.onReaderReady(plugin, Session._snapshot)
    else
        ChapterMode.clearActiveChapter(Session._snapshot)
        Snapshot.refresh(Session._snapshot)
        -- sidecar 缺失（清缓存后重下 / 换设备）时文档停在开头：用本地进度回落。
        require("reader.session.progress").applyLocalPending(Session._snapshot)
        Snapshot.refresh(Session._snapshot)
        require("reader.session.auto_toc").start(Session._snapshot)
        ensureCover(ui, identity)
    end
    span:lap("snapshot")
    updateReadState(Session._snapshot)
    bootstrapReading(plugin, Session._snapshot, skip_pull)
    span:lap("bootstrap")
    if chapter_mode then
        ChapterMode.afterBootstrap(plugin, Session._snapshot)
        span:lap("after")
    end
    span:finish(Session.SLOW_READY_MS, identity.source_id, chapter_mode and "chapter" or "book")
end

--- 推送当前进度和注解。
---@param plugin table
local function syncReading(plugin)
    local identity = Session._snapshot and Session._snapshot.identity
    local source = identity and identity.source
    -- 进度要在时长之后推：微信时长上报也会写云端位置，最后落地的必须是精确进度。
    if source then source:onEvent("reading_stopped", { identity = identity }) end
    local waiting, progress_saved = 2, false
    local function pushProgress()
        waiting = waiting - 1
        if waiting > 0 or not progress_saved or not source.syncProgressAsync then return end
        -- 关书只负责把本地新版本推上去。立即回拉可能读到微信尚未收敛的
        -- 旧值，再把刚上传的进度覆盖掉；远端拉取统一留给下次 ReaderReady。
        source:syncProgressAsync({
            identity = identity,
            dirty_only = true,
        }, function() end)
    end
    if source and identity then
        require("reader.session.progress").save(Session._snapshot, function(ok)
            progress_saved = ok
            pushProgress()
        end)
        require("reader.session.note").save(plugin.ui, identity, nil, function(ok)
            if ok and source.syncNotesAsync then
                -- 关书只推脏注解；完整 pull 留给下次 ReaderReady，避免未收敛远端盖本地。
                source:syncNotesAsync({
                    identity = identity,
                    dirty_only = true,
                }, function() end)
            end
        end)
    end
    require("reader.session.stats").stop(function()
        if source and source.syncStatsAsync then
            source:syncStatsAsync({ dirty_only = true }, function()
                if identity then pushProgress() end
            end)
        elseif source and identity then
            pushProgress()
        end
    end)
end

--- CloseDocument：结清阅读状态；切章保留目录，真正关书清除全部章节状态。
---@param plugin table Book 插件实例
function Session.onCloseDocument(plugin)
    local Perf = require("utils.perf")
    local started_at = Perf.now()
    if Session._snapshot and plugin.ui then
        require("reader.prefs").captureAndSave(plugin.ui, Session._snapshot.identity)
    end
    Perf.slow("close prefs", started_at)
    syncReading(plugin)
    Perf.slow("close sync", started_at)
    require("reader.session.auto_toc").stop(Session._snapshot)
    Perf.slow("close total", started_at)
    if ChapterMode.onCloseDocument(Session._snapshot) then
        require("reader.session.progress").clearConflicts()
    end
    Session._snapshot = nil
end

--- PageUpdate（分页视图）：结清上一页统计、刷新快照，并通知属主源。重画归 ReaderView，这里不再 setDirty（会多一次整屏刷新）。
---@param plugin table Book 插件实例
---@param page number|nil
function Session.onPageUpdate(plugin, page)
    local session = Session._snapshot
    if not session then
        require("reader.session.stats").onPage(nil)
        return
    end
    -- 每翻一页都走这里，这里慢就是「翻不动」：超 100ms 记下来。
    local Perf = require("utils.perf")
    local started_at = Perf.now()
    Snapshot.refresh(session, page)
    updateReadState(session)
    require("reader.session.stats").onPage(session)
    require("utils.extension").emit("reader.page_updated", plugin)
    local source = session.identity.source
    if source then
        source:onEvent("page_changed", {
            identity = session.identity,
            page = session.page,
            total_pages = session.total_pages,
            percent = session.percent,
            position = session.position,
        })
    end
    Perf.slow("page.update", started_at)
end

--- PosUpdate（滚动视图）：同 PageUpdate。
---@param plugin table Book 插件实例
---@param _pos number
---@param page number|nil
function Session.onPosUpdate(plugin, _pos, page)
    Session.onPageUpdate(plugin, page)
end

--- 注解变化：落盘后已在线才 dirty push；离线留脏给源 onNetworkConnected，不弹联网提示。
---@param plugin table Book 插件实例
---@param items table|nil KOReader 变更描述；完整数据从 annotation.annotations 读取，删除判据在 index_modified
function Session.onAnnotationsModified(plugin, items)
    if not Session._snapshot then return end
    local identity = Session._snapshot.identity
    require("reader.session.note").save(plugin.ui, identity, items, function(ok)
        if not ok then return end
        local source = identity and identity.source
        if not source or not source.syncNotesAsync then return end
        if not require("ui/network/manager"):isConnected() then return end
        source:syncNotesAsync({ identity = identity, dirty_only = true }, function() end)
    end)
end

--- 休眠前：结清计时并同步当前进度和注解；会话继续保留。
---@param plugin table Book 插件实例
function Session.onSuspend(plugin)
    if not plugin.ui.document then return end
    if Session._snapshot then
        require("reader.prefs").captureAndSave(plugin.ui, Session._snapshot.identity)
    end
    syncReading(plugin)
end

--- 唤醒后恢复当前阅读会话的统计计时，并通知属主源（休眠时停掉的定时任务在这里重启）。
---@param plugin table Book 插件实例
function Session.onResume(plugin)
    if not plugin.ui.document then
        return
    end
    -- KOReader 在唤醒时可能重新应用 ReaderFooter/status_line 设置。
    -- 月读的用户偏好是持久状态，恢复阅读时必须再次收敛原生栏状态。
    require("utils.extension").emit("reader.preferences", plugin.ui)
    -- screensaver 关 widget 后若不刷，eInk 上会留白；无 screensaver widget 的路径
    -- （disable / no_cover）也不会走 Kindle 的 setDirty("all","full")。
    require("ui/uimanager"):setDirty(plugin.ui.dialog or "all", "full")
    local session = Session._snapshot
    if not session then return end
    require("reader.session.stats").start(session)
    local source = session.identity.source
    if source then
        source:onEvent("reading_resumed", {
            identity = session.identity,
            position = require("reader.session.progress").position(session),
        })
    end
end

--- 从目录或其他阅读 UI 切换到指定章节；只有连续章节会话能切，整书返回 false。
---@param idx integer 目标章节序号
---@param opts { within: number|nil, direction: "prev"|"next"|nil, xpointer: string|nil }|nil
---@return boolean started
function Session.gotoChapter(idx, opts)
    return ChapterMode.gotoChapter(Session._snapshot, idx, opts)
end

--- 重新下载当前章（只清本章缓存）；只有连续章节会话可用。
---@return boolean started
function Session.reloadChapter()
    return ChapterMode.reloadChapter(Session._snapshot)
end

return Session
