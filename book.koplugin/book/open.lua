--[[--
打开书籍：整本 materialize 或 按章 materialize。

@module koplugin.book.book.open
--]]

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
local Store = require("book.store")
local SourceError = require("source.error")
local Content = require("book.content")
local _ = require("gettext")

local Open = {}

--- 关闭书架桌面与详情页。
---@param plugin table
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

--- 下一拍打开阅读器。
---@param path string
local function showReader(path)
    local ReaderUI = require("apps/reader/readerui")
    UIManager:nextTick(function()
        ReaderUI:showReader(path)
    end)
end

--- 数据源是否支持整本或按章阅读。
---@param source BookSource|nil
---@return boolean
local function canRead(source)
    local caps = source and source.capabilities and source:capabilities() or {}
    return caps.whole_book == true or caps.chapters == true
end

--- 整本下载/缓存后打开。
---@param plugin table
---@param book Book
---@param source BookSource
---@param ref BookRef
local function openWholeBook(plugin, book, source, ref)
    local Chapter = require("book.chapter")
    Chapter.clear()
    Store.remember(book)
    local path = Store.bookFilePath(ref.book_key, ref.source_id)
    logger.dbg("book.open whole", ref.stable_id, path)

    --- 登记并进入阅读器。
    local function doOpen()
        Store.touch(path, ref)
        closeDesktop(plugin)
        logger.info("book.open reader", path)
        showReader(path)
    end

    if Content.isValidEpub(path) then
        logger.dbg("book.open cache hit", path)
        doOpen()
        return
    end
    -- 半截/损坏缓存不当命中
    pcall(os.remove, path)

    NetworkMgr:runWhenOnline(function()
        local job_key = "whole:" .. ref.book_key
        Content.sharedJob(job_key, function(finish)
            local title = book.title
                or (ref.stable_id:match("([^/\\]+)$") or ref.stable_id)
            local size = tonumber(book.fileSize or book.filesize or book.size or book.file_size)
            if (not size or size <= 0) and source.probeFileSize then
                size = source:probeFileSize(ref)
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

            local tmp = path .. ".part"
            local ok, err = source:materializeWhole(ref, tmp, dialog and function(bytes)
                dialog:reportProgress(bytes)
            end or nil)

            if dialog then
                dialog:close()
            end
            if not ok then
                os.remove(tmp)
                finish(false, nil, err)
                return
            end
            if not Content.isValidEpub(tmp) then
                os.remove(tmp)
                finish(false, nil, SourceError.io(_("下载文件校验失败")))
                return
            end
            os.remove(path)
            if not os.rename(tmp, path) then
                os.remove(tmp)
                finish(false, nil, SourceError.io(_("无法保存文件")))
                return
            end
            finish(true, path)
        end, function(ok, _path, err)
            if not ok then
                logger.warn("book.open download failed", ref.stable_id, SourceError.message(err))
                UIManager:show(InfoMessage:new{ text = SourceError.message(err) or _("下载失败") })
                return
            end
            logger.info("book.open download ok", ref.stable_id)
            doOpen()
        end)
    end)
end

--- 按章准备并打开起始章。
---@param plugin table
---@param book Book
---@param source BookSource
---@param ref BookRef
local function openChapterBook(plugin, book, source, ref)
    Store.remember(book)

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{ text = _("正在准备章节…"), timeout = 1 })
        local Chapter = require("book.chapter")
        Chapter.prepareOpenAsync(source, book, ref, function(ok, prep, err)
            if not ok or not prep then
                UIManager:show(InfoMessage:new{ text = SourceError.message(err) or err or _("无法获取目录") })
                return
            end
            local start_idx = prep.start_idx or 1
            Chapter.ensureAsync(source, ref, start_idx, prep.toc, function(eok, path, e2)
                if not eok or not path then
                    UIManager:show(InfoMessage:new{ text = SourceError.message(e2) or e2 or _("章节下载失败") })
                    return
                end
                Chapter.bind({
                    plugin = plugin,
                    source = source,
                    book = prep.book or book,
                    ref = ref,
                    toc = prep.toc,
                    idx = start_idx,
                })
                Store.touch(path, ref, { chapter_idx = start_idx })
                closeDesktop(plugin)
                logger.info("book.open chapter", ref.stable_id, start_idx, path)
                showReader(path)
                Chapter.prefetchAround(start_idx)
            end)
        end)
    end)
end

--- 打开书籍：整本 materialize 或按章 materialize。
---@param plugin table
---@param book Book
---@param source BookSource|nil 打开时捕获的源；缺省取 registry.current
function Open.book(plugin, book, source)
    source = source or require("source.registry").current()
    if not source then
        UIManager:show(InfoMessage:new{ text = _("无数据源") })
        return
    end
    local ref = Store.refOf(book)
    if not ref then
        UIManager:show(InfoMessage:new{ text = _("无效书籍身份") })
        return
    end
    if not canRead(source) then
        UIManager:show(InfoMessage:new{ text = _("当前数据源不支持阅读") })
        return
    end
    local caps = source:capabilities() or {}
    if caps.chapters then
        openChapterBook(plugin, book, source, ref)
    else
        openWholeBook(plugin, book, source, ref)
    end
end

return Open
