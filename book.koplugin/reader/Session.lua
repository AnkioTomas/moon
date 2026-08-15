--[[--
书籍级阅读会话：打开 → 阅读 → 关闭 的统一编排。

收编 main.lua 的阅读期编排（Tracker / Progress / Chapters / 源事件），
并维护当前阅读状态供阅读页管理器（reader.reader）与进度条（reader.bars）查询。

身份来源：章会话（chapters）优先——换源后仍读旧书时 registry.current 已不对；
否则 Store.identityFor(document.file)。都没有 → 会话不活跃，无身份文档行为零变化。

切章（switchDocument）会关旧文档再开新文档：CloseDocument 清状态，
ReaderReady 依章会话重建——期间 bars/panel 短暂不活跃属正常。

@module koplugin.book.reader.session
--]]

local Store = require("book.store")

local Session = {
    ---@type { plugin: table, source: table|nil, ref: BookRef|nil, book: table|nil, chapter_idx: number|nil, chapter_count: number|nil, page: number, total_pages: number, percent: number }|nil
    _cur = nil,
}

--- 是否有活跃阅读会话（仅源身份书籍）。
---@return boolean
function Session.isActive()
    return Session._cur ~= nil
end

--- 当前会话状态（bars / panel 读取用）。
---@return table|nil
function Session.current()
    return Session._cur
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
    local Chapter = require("book.chapter")
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
    local Chapter = require("book.chapter")
    local ref, chapter_idx, book, source
    if Chapter.isActive() then
        ref = Chapter.ref()
        source = Chapter.source()
        book = Chapter.book()
        chapter_idx = Chapter.currentIdx()
    else
        local id = Store.identityFor(ui.document.file)
        if id then
            ref = id.ref
            chapter_idx = id.chapter_idx
        end
    end

    require("stats.tracker").start(ui)
    if Chapter.isActive() then
        require("chapters.patches").enable()
        require("chapters.patches").wrapReaderUi(ui)
        Chapter.onReaderReady(ui)
    end
    require("book.progress").pull(ui, plugin:getSource(), false)

    if ref then
        Session._cur = {
            plugin = plugin,
            source = source or plugin:getSource(),
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

    require("reader.reader").attach(plugin)
    plugin:emitToSource("reader_ready")
end

--- CloseDocument：推进度；结清统计；通知源；切章由 ReaderReady 重建会话。
---@param plugin table
---@return nil
function Session.onCloseDocument(plugin)
    local ui = plugin and plugin.ui
    require("book.progress").push(ui, plugin:getSource(), false)
    require("stats.tracker").stop()
    plugin:emitToSource("document_close")
    local closed = ui and ui.document and ui.document.file
    require("book.chapter").onCloseDocument(closed)
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
    require("reader.reader").refresh(plugin)
    cur.plugin:emitToSource("page_changed", {
        ref = cur.ref,
        book = cur.book,
        page = cur.page,
        total_pages = cur.total_pages,
        percent = cur.percent,
        chapter_idx = cur.chapter_idx,
    })
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
    require("book.progress").push(ui, plugin:getSource(), false)
    require("stats.tracker").stop()
    plugin:emitToSource("suspend")
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
    return require("book.chapter").onEndOfBook()
end

--- 章首：按章会话自动上一章。
---@return boolean handled
function Session.onStartOfBook()
    return require("book.chapter").onStartOfBook()
end

return Session
