--[[--
按书籍身份解析属主源，并打开源返回的物理文档。

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

--- 下一拍打开阅读器；用户已切到其他文档时丢弃本次交接。
---@param plugin table
---@param path string
---@param generation integer
---@param done fun(ok: boolean) 交接给 ReaderUI 时 true，因用户已在读别的文档而放弃时 false
local function showReader(plugin, path, generation, done)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        if generation ~= Open.generation then return end
        local ui = ReaderUI.instance
        if ui and ui.document and ui.document.file ~= path then
            logger.dbg("desktop.open showReader skip: user reading other doc")
            done(false)
            return
        end
        local desktop = plugin and plugin.desktop
        logger.info("desktop.open reader", path)
        done(true)
        ReaderUI:showReader(path, nil, nil, nil, function()
            -- KOReader 在此回调返回后才把 ReaderUI 放入窗口栈；再排一拍，
            -- 避免先关全屏桌面导致底层 FileManager 被重绘出来。
            UIManager:nextTick(function()
                closeDesktop(plugin, desktop)
            end)
        end)
    end)
end

--- 打开书籍：Book 身份决定属主源，源负责返回已登记的物理文档。
---@param plugin table
---@param book Book
---@param on_done fun(ok: boolean)|nil 异步结束（成功开阅读器或失败）后回调；被更新一代打开取消时不调用
function Open.book(plugin, book, on_done)
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
    Open.pending_job = source:openBookAsync(identity, nil, function(path, open_err, meta)
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
        showReader(plugin, path, generation, done)
    end)
end

return Open
