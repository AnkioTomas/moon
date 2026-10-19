--[[--
按书籍身份解析属主源，并打开源返回的物理文档。

Open.generation + pending_job：新的打开会取消尚未交接给 Reader 的旧打开，过期回调丢弃，调用方不必防抖。
用 book.source_id 解析属主源，不用 Registry.current()（换源串书的根因）；关桌面排在 Reader 入栈之后一拍，避免闪 FM。

@module koplugin.book.desktop.open
--]]

local UIManager = require("ui/uimanager")
local logger = require("utils.log")
local Perf = require("utils.perf")
local Store = require("book.store")
local _ = require("gettext")
local Toast = require("ui.themes.widgets.toast")

local Open = {
    pending_job = nil,
    generation = 0,
}

--- 关闭仍属于本次打开动作的书架桌面与详情页。
---@param plugin table
---@param desktop table|nil
local function closeDesktop(plugin, desktop)
    if not plugin or not desktop or plugin.desktop ~= desktop then return end
    if desktop.detail then
        UIManager:close(desktop.detail)
        desktop.detail = nil
    end
    UIManager:close(desktop)
    plugin.desktop = nil
end

--- 取消上一次尚未交给 ReaderReady 的打开动作。
local function cancelPending()
    Open.generation = Open.generation + 1
    local job = Open.pending_job
    Open.pending_job = nil
    if job and job.cancel then job:cancel() end
end

--- 超大 EPUB 且从没开过（没有 sidecar）：首次排版最容易把设备内存吃光。
---@param path string
---@return boolean
local function isHeavyFirstOpen(path)
    if not path:lower():match("%.epub$") then return false end
    local size = require("libs/libkoreader-lfs").attributes(path, "size") or 0
    return size >= require("reader.prefs").BIG_BOOK_BYTES and not require("docsettings"):hasSidecarFile(path)
end

--- 下一拍打开阅读器；用户已切到其他文档时丢弃本次交接。
---@param plugin table
---@param path string
---@param generation integer
---@param done fun(ok: boolean) 交接给 ReaderUI 时 true，因用户已在读别的文档而放弃时 false
local function showReader(plugin, path, generation, done)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(require("ui.guard").wrap("open document", function()
        if generation ~= Open.generation then return end
        local ui = ReaderUI.instance
        if ui and ui.document and ui.document.file ~= path then
            logger.dbg("desktop.open showReader skip: user reading other doc")
            done(false)
            return
        end
        local desktop = plugin and plugin.desktop
        local function open()
            logger.info("desktop.open reader", path)
            done(true)
            ReaderUI:showReader(path, nil, nil, nil, function()
                -- KOReader 在此回调返回后才把 ReaderUI 放入窗口栈；再排一拍，
                -- 避免先关全屏桌面导致底层 FileManager 被重绘出来。
                UIManager:nextTick(require("ui.guard").wrap("open document", function()
                    closeDesktop(plugin, desktop)
                end))
            end)
        end
        if isHeavyFirstOpen(path) then
            require("ui.themes.widgets.confirm"):new{
                text = _("这本书文件很大（超过 20 MB），首次打开时 KOReader 的排版引擎可能占满内存，导致卡死甚至被系统强制结束。这不是月读的问题，而是 KOReader 排版引擎处理超大文件的限制。已默认关闭内嵌字体与内嵌样式以减轻负担；若仍卡死，建议先拆分书籍或压缩其中的图片。\n\n仍要打开吗？"),
                ok_text = _("仍然打开"),
                cancel_text = _("取消"),
                ok_callback = open,
                cancel_callback = function() done(false) end,
            }:show()
            return
        end
        open()
    end))
end

--- 打开书籍：Book 身份决定属主源，源负责返回已登记的物理文档。
---@param plugin table
--- 上次读的是原书的衍生版（排版 / 双语）且文件还在：源登记的是原书路径，这里改回上次的版本。
---@param identity BookIdentity
---@param last_path string|nil 开书前 books.path
---@param path string 源返回的路径
---@return string
local function rememberDerived(identity, last_path, path)
    if not last_path or last_path == path then return path end
    if require("reader.session.derived_note").originOf(last_path) ~= path then return path end
    if require("libs/libkoreader-lfs").attributes(last_path, "mode") ~= "file" then return path end
    if not Store.touch(last_path, identity) then return path end
    return last_path
end

---@param book Book
---@param on_done fun(ok: boolean)|nil 异步结束（成功开阅读器或失败）后回调；被更新一代打开取消时不调用
---@param opts table|nil 交给源 openBookAsync（如 chapter_idx 指定打开哪章）
function Open.book(plugin, book, on_done, opts)
    --- 只在本代打开仍有效时通知调用方。
    ---@param ok boolean
    local function done(ok)
        if on_done then on_done(ok) end
    end
    if not book or not book.source_id or not book.stable_id then
        Toast:new{ text = _("无效书籍身份") }:show()
        done(false)
        return
    end

    local source, err = require("source.registry").resolve(book.source_id)
    if not source then
        Toast:new{ text = err or _("数据源不可用") }:show()
        done(false)
        return
    end
    if not source.openBookAsync then
        Toast:new{ text = _("当前数据源不支持打开书籍") }:show()
        done(false)
        return
    end

    cancelPending()
    local generation = Open.generation
    Store.rememberMany({ book })
    local identity = {
        source_id = book.source_id,
        stable_id = book.stable_id,
        source = source,
        book = book,
    }
    local started_at = Perf.now()
    local last = require("book.books_db").get(book.source_id, book.stable_id)
    local last_path = last and last.path
    Open.pending_job = source:openBookAsync(identity, opts, function(path, open_err, meta)
        if generation ~= Open.generation then return end
        Open.pending_job = nil
        logger.dbg("book.perf open.source", Perf.elapsedMs(started_at), "ms", book.source_id, path ~= nil)
        if meta and meta.handled then
            done(true)
            return
        end
        if not path then
            Toast:new{ text = open_err or _("无法打开书籍") }:show()
            done(false)
            return
        end
        showReader(plugin, rememberDerived(identity, last_path, path), generation, done)
    end)
end

return Open
