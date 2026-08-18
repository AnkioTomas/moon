--[[--
书籍级阅读会话：打开 → 阅读 → 关闭 的统一编排。

收编 main.lua 的阅读期编排（Tracker / Progress / Chapters / 源事件），
并维护当前阅读状态供阅读页管理器（ui.reader）与进度条（ui.reader.bars）查询。

无自绘布局；状态机：

  openDocument ──► _cur 活跃 ──► bars/panel 可读
       │                │
       │           page_changed / 切章
       │                │
  CloseDocument ──► _cur = nil（bars 停画）

身份来源：所有文档统一由 Store.ensureIdentity(document.file) 反向解析；
章节会话只提供书籍元数据和章节编排。源实例按 ref.source_id 解析（owningSource），
绝不拿 current 操作旧书。插件缓存内找不到身份时提示从 Book 桌面打开。

切章（switchDocument）会关旧文档再开新文档：CloseDocument 清状态，
ReaderReady 依章会话重建——期间 bars/panel 短暂不活跃属正常。

@module koplugin.book.ui.reader.session
--]]

local Store = require("book.store")

local function promptOpenFromDesktop()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local _ = require("gettext")
    UIManager:show(InfoMessage:new{ text = _("请从 Book 桌面打开此书") })
end

local Session = {
    ---@type { plugin: table, source: table|nil, ref: BookRef|nil, book: table|nil, chapter_idx: number|nil, chapter_count: number|nil, page: number, total_pages: number, percent: number }|nil
    _cur = nil,
}

--- 当前阅读会话快照；锁屏等只读消费者使用。
---@return table|nil
function Session.current()
    return Session._cur
end

--- 属主源解析：ref 属于哪个源就用哪个源实例。
--- 章会话的 source 是 bind 时捕获的（已对）；整本书在这里按 ref.source_id 建非活跃实例。
--- 属主源不可用返回 nil：跳过源相关同步，也不许错用 current（串书根因）。
---@param plugin table
---@param ref BookRef|nil
---@return BookSource|nil
local function owningSource(plugin, ref)
    local current = plugin:getSource()
    if not ref then
        return current
    end
    if current and current.id == ref.source_id then
        return current
    end
    local ok, src = pcall(function()
        return require("source.registry").create(ref.source_id)
    end)
    if ok then
        return src
    end
    return nil
end

--- 是否有活跃阅读会话（仅源身份书籍）。
---@return boolean
function Session.isActive()
    return Session._cur ~= nil
end

--- 当前文档页数（取不到按 0）。
---@param ui table|nil
---@return number
local function totalPages(ui)
    local doc = ui and ui.document
    if doc and doc.getPageCount then
        return tonumber(doc:getPageCount()) or 0
    end
    return 0
end

--- 刷新会话的页码 / 百分比 / 章号快照。
---@param ui table|nil
---@param page number|nil
local function snapshot(ui, page)
    local cur = Session._cur
    if not cur then
        return
    end
    cur.page = tonumber(page)
        or (ui and ui.getCurrentPage and tonumber(ui:getCurrentPage()))
        or cur.page
    cur.total_pages = totalPages(ui)
    if ui then
        cur.percent = require("book.progress").fraction(ui) * 100
    end
    local Chapter = require("chapters.init")
    if Chapter.isActive() then
        cur.chapter_idx = Chapter.currentIdx()
        cur.chapter_count = Chapter.chapterCount()
    else
        cur.chapter_count = nil
    end
end

--- ReaderReady：建会话；统计计时；按章落点；拉进度；挂阅读页管理器；通知源。
---@param plugin table
---@return nil
function Session.onReaderReady(plugin)
    local ui = plugin and plugin.ui
    if not ui or not ui.document then
        return
    end
    local Chapter = require("chapters.init")
    local ref, chapter_idx, book, source, identity
    identity = Store.ensureIdentity(ui.document.file)
    if not identity and require("utils.paths").isMoonPath(ui.document.file) then
        Session._cur = nil
        promptOpenFromDesktop()
        return
    end
    if identity then
        ref = identity.ref
        chapter_idx = identity.chapter_idx
        -- 章节会话只补充元数据；身份仍以物理路径解析结果为准。
        if Chapter.isActive() then
            book = Chapter.book()
        end
        -- 源跟 ref 走，不跟 current 走：换源后继续读旧书，用属主源实例
        -- （current 是新源，直接拿它拉/推旧 stable_id 就是「串书」根因）
        source = owningSource(plugin, ref)
    end

    require("stats.tracker").start(ui, identity or (ref and { ref = ref }))
    if Chapter.isActive() then
        require("chapters.patches").enable()
        require("chapters.patches").wrapReaderUi(ui)
        Chapter.onReaderReady(ui)
    end
    if source then
        require("book.progress").pull(ui, source, false)
    end

    if ref then
        Session._cur = {
            plugin = plugin,
            source = source,
            ref = ref,
            book = book,
            chapter_idx = chapter_idx,
            page = 1,
            total_pages = 0,
            percent = 0,
        }
        snapshot(ui)
    else
        Session._cur = nil
    end

    require("ui.reader").attach(plugin)
    if source then
        plugin:emitToSource("reader_ready", nil, source)
    end
end

--- CloseDocument：推进度；结清统计；通知源；切章由 ReaderReady 重建会话。
---@param plugin table
---@return nil
function Session.onCloseDocument(plugin)
    local ui = plugin and plugin.ui
    local cur = Session._cur
    require("ui.reader").closeToolbar()
    require("stats.tracker").stop()
    if cur and cur.source then
        require("book.progress").push(ui, cur.source, false)
        require("annotations.sync").push(ui, cur.source, cur.ref)
        plugin:emitToSource("document_close", nil, cur.source)
    end
    local closed = ui and ui.document and ui.document.file
    -- 真关书才清进度冲突记忆；切章（switchDocument）不算，否则会每章重复询问
    if require("chapters.init").onCloseDocument(closed) then
        require("book.progress").clearConflicts()
    end
    if not cur then
        Session._cur = nil
        return
    end
    Session._cur = nil
end

--- 翻页：统计换页；更新快照；刷新进度条；分发 page_changed。
---@param plugin table
---@param page number|nil
---@return nil
local function onPage(plugin, page)
    local ui = plugin and plugin.ui
    require("stats.tracker").onPage(ui, page)
    local cur = Session._cur
    if not cur then
        return
    end
    snapshot(ui, page)
    require("ui.reader").refresh(plugin)
    if cur.source then
        cur.plugin:emitToSource("page_changed", {
            ref = cur.ref,
            book = cur.book,
            page = cur.page,
            total_pages = cur.total_pages,
            percent = cur.percent,
            chapter_idx = cur.chapter_idx,
        }, cur.source)
    end
end

--- 翻页（分页视图）。
---@param plugin table
---@param page number
---@return nil
function Session.onPageUpdate(plugin, page)
    onPage(plugin, page)
end

--- 翻页（滚动视图）。
---@param plugin table
---@param page number|nil
---@return nil
function Session.onPosUpdate(plugin, page)
    onPage(plugin, page)
end

--- 休眠前：推进度；结清统计；通知源。
---@param plugin table
---@return nil
function Session.onSuspend(plugin)
    local ui = plugin and plugin.ui
    if not ui or not ui.document then
        return
    end
    local cur = Session._cur
    require("stats.tracker").stop()
    if cur and cur.source then
        require("book.progress").push(ui, cur.source, false)
        require("annotations.sync").push(ui, cur.source, cur.ref)
        plugin:emitToSource("suspend", nil, cur.source)
    end
end

--- 唤醒：恢复阅读统计计时。
---@param plugin table
---@return nil
function Session.onResume(plugin)
    local ui = plugin and plugin.ui
    if not ui or not ui.document then
        return
    end
    require("stats.tracker").start(ui)
end

--- 章末：按章会话自动下一章。
---@return boolean handled
function Session.onEndOfBook()
    return require("chapters.init").onEndOfBook()
end

--- 章首：按章会话自动上一章。
---@return boolean handled
function Session.onStartOfBook()
    return require("chapters.init").onStartOfBook()
end

return Session
