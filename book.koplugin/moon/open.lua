--[[--
打开书籍：本地缓存命中直接读；否则联网下载。

@module koplugin.book.moon.open
--]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local lfs = require("libs/libkoreader-lfs")
local Cache = require("moon.cache")
local SourceRegistry = require("source.registry")
local _ = require("gettext")

local Open = {}

local function closeDesktop(plugin)
    if not plugin or not plugin.desktop then
        return
    end
    if plugin.desktop.detail then
        UIManager:close(plugin.desktop.detail)
        plugin.desktop.detail = nil
    end
    UIManager:close(plugin.desktop)
    plugin.desktop = nil
end

local function showReader(path)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        ReaderUI:showReader(path)
    end)
end

--- 打开书。打开前关掉桌面，避免阅读栈下面压着全屏页。
function Open.book(plugin, book)
    local filename = book and book.filename
    if not filename or filename == "" then
        UIManager:show(InfoMessage:new{ text = _("无效文件名") })
        return
    end
    Cache.remember(book)
    local path = Cache.bookPath(filename)

    local function doOpen()
        Cache.touch(path, filename)
        closeDesktop(plugin)
        showReader(path)
    end

    if lfs.attributes(path, "mode") == "file" then
        doOpen()
        return
    end

    NetworkMgr:runWhenOnline(function()
        local source = SourceRegistry.getActive()
        local title = book.bookName or book.title
            or (filename:match("([^/\\]+)$") or filename)
        local size = tonumber(book.fileSize or book.filesize or book.size or book.file_size)
        if not size or size <= 0 then
            size = source:probeFileSize(filename)
        end

        local dialog
        local ok_dlg, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
        if ok_dlg and ProgressbarDialog then
            dialog = ProgressbarDialog:new{
                title = _("正在下载…"),
                subtitle = title,
                progress_max = (size and size > 0) and size or nil,
                refresh_time_seconds = 1,
                dismissable = false,
            }
            dialog:show()
        else
            UIManager:show(InfoMessage:new{ text = _("正在下载…") })
        end

        local ok, err = source:downloadBook(filename, path, dialog and function(bytes)
            dialog:reportProgress(bytes)
        end or nil)

        if dialog then
            dialog:close()
        end
        if not ok then
            UIManager:show(InfoMessage:new{ text = err or _("下载失败") })
            return
        end
        doOpen()
    end)
end

return Open
