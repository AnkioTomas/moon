--[[--
按书籍身份解析属主源，并打开源返回的物理文档。

@module koplugin.book.book.open
--]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local Store = require("book.store")
local _ = require("gettext")

local Open = {}

local pending_job
local open_generation = 0

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
    open_generation = open_generation + 1
    local job = pending_job
    pending_job = nil
    if job and job.cancel then job.cancel() end
end

--- 下一拍打开阅读器；用户已切到其他文档时丢弃本次交接。
---@param plugin table
---@param path string
---@param generation integer
local function showReader(plugin, path, generation)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        if generation ~= open_generation then return end
        local ui = ReaderUI.instance
        if ui and ui.document and ui.document.file ~= path then
            logger.dbg("book.open showReader skip: user reading other doc")
            return
        end
        local desktop = plugin and plugin.desktop
        logger.info("book.open reader", path)
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
function Open.book(plugin, book)
    if not book or not book.source_id or not book.stable_id then
        UIManager:show(InfoMessage:new{ text = _("无效书籍身份") })
        return
    end

    local source, err = require("source.registry").resolve(book.source_id)
    if not source then
        UIManager:show(InfoMessage:new{ text = err or _("数据源不可用") })
        return
    end
    if not source.openBookAsync then
        UIManager:show(InfoMessage:new{ text = _("当前数据源不支持打开书籍") })
        return
    end

    cancelPending()
    local generation = open_generation
    Store.rememberMany({ book })
    local identity = {
        source_id = book.source_id,
        stable_id = book.stable_id,
        source = source,
        book = book,
    }
    pending_job = source:openBookAsync(identity, nil, function(path, open_err)
        if generation ~= open_generation then return end
        pending_job = nil
        if not path then
            UIManager:show(InfoMessage:new{ text = open_err or _("无法打开书籍") })
            return
        end
        showReader(plugin, path, generation)
    end)
end

return Open
