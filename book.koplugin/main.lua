--[[--
月读插件入口 — 事件接线板。

KOReader 会为 FileManager 和 Reader 各建一个插件实例；
关书后 FM 侧实例才是开桌面的宿主。

本文件只做生命周期转发：桌面 / 阅读会话 / 源事件 / 脏同步重试。
业务规则在 book/、ui/reader/session、source/。

@module koplugin.book
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("utils.log")
require("l10n")
local _ = require("gettext")

local SourceRegistry = require("source.registry")
local Desktop = require("ui.desktop")
local Host = require("host")
local Open = require("book.open")

--- 调桌面方法；已 Destroy 则跳过。
---@param plugin table
---@param name string
---@param ... any
local function desktopLife(plugin, name, ...)
    local desktop = plugin.desktop
    if not desktop then return end
    local life = desktop.lifecycle
    if life and life.state == "Destroy" then return end
    local fn = desktop[name]
    if type(fn) == "function" then
        fn(desktop, ...)
    end
end

--- Book 插件实例（FM / Reader 各一份）
---@class BookPlugin : WidgetContainer
---@field is_doc_only boolean
---@field desktop BookDesktop|nil 当前全屏桌面实例
---@field path string 插件根目录
---@field ui table|nil KOReader FileManager / ReaderUI
local BookPlugin = WidgetContainer:extend {
    name = "book",
    is_doc_only = false,
}

-- ── 生命周期事件 ─────────────────────────────────────

--- 插件初始化：挂接 Host（菜单 / 开机打开等）与各增强模块
---@return nil
function BookPlugin:init()
    if not require("ko_version").check() then
        return
    end
    logger.start()
    logger.info("book plugin init", self.ui and self.ui.document and "reader" or "filemanager")
    Host.onCreate(self)
    require("translate.init").onCreate()
    require("baike.init").onCreate()
    require("dictionary.init").onCreate()
    require("ui.panel.native").onCreate(self.ui)
    require("lockscreen.init").onCreate()
    require("remote.init").onCreate()
    require("ime.init").onCreate()
    require("patch.manager").onCreate({ plugin_root = self.path })
    if self.ui and self.ui.document then
        self:emitToSource("reader_open")
    end
end

--- FM 显示时同步接管（避免 FileManager 先闪一帧）
---@return nil
function BookPlugin:onShow()
    logger.dbg("book lifecycle show")
    Host.onShow(self)
    if self.ui and not self.ui.document then
        self:emitToSource("fm_open")
    end
end

--- Dispatcher / 手势：打开月读
---@return boolean 已处理
function BookPlugin:onBookOpenShelf()
    self:openDesktop()
    return true
end

--- Dispatcher 手势：强制刷新当前书籍的 X-Ray。
---@return boolean
function BookPlugin:onBookXrayRefresh()
    if not self.ui or not self.ui.document then
        return false
    end
    require("xray.ui").refresh(self.ui)
    return true
end

--- 主菜单回调（由 Host.registerMenu → registerToMainMenu 挂上）
---@param menu_items table KOReader 主菜单项表（就地写入）
---@return nil
function BookPlugin:addToMainMenu(menu_items)
    menu_items.book_library = {
        text = _("月读"),
        sorting_hint = "setting",
        callback = function()
            self:openDesktop()
        end,
    }
end

--- 读 sidecar 前：把全书排版偏好写进本章 sidecar，由原生模块加载
---@param doc_settings table
---@param document table
---@return nil
function BookPlugin:onDocSettingsLoad(doc_settings, document)
    require("book.reader_prefs").inject(doc_settings, document)
end

--- 阅读器就绪：建阅读会话；统计计时；拉进度；按章落点；挂阅读页
---@return nil
function BookPlugin:onReaderReady()
    require("ui.reader.session").onReaderReady(self)
end

--- 关文档：推进度；结清统计；通知源；切章则保留会话，真关书才清
---@return nil
function BookPlugin:onCloseDocument()
    logger.info("book lifecycle close_document")
    require("ui.reader.session").onCloseDocument(self)
end

--- 章末：按章会话自动下一章
---@return boolean
function BookPlugin:onEndOfBook()
    logger.dbg("book lifecycle end_of_book")
    return require("ui.reader.session").onChapterBoundary(1)
end

--- 章首：按章会话自动上一章
---@return boolean
function BookPlugin:onStartOfBook()
    logger.dbg("book lifecycle start_of_book")
    return require("ui.reader.session").onChapterBoundary(-1)
end

--- 休眠前：结清阅读状态，生成锁屏图，停远程服务，暂停桌面。
---@return nil
function BookPlugin:onSuspend()
    logger.info("book lifecycle suspend")
    require("ui.reader.session").onPause(self)
    require("lockscreen.init").onPause()
    require("remote.init").onPause()
    desktopLife(self, "onPause")
    logger.flush()
end

--- 唤醒：恢复阅读统计与后台服务；桌面在窗口栈上时自行收 Resume。
---@return nil
function BookPlugin:onResume()
    logger.info("book lifecycle resume")
    require("ui.reader.session").onResume(self)
    require("lockscreen.init").onResume()
    require("remote.init").onResume()
end

--- 退出：停更新任务、远程服务，并销毁仍打开的桌面。
---@return nil
function BookPlugin:onExit()
    logger.info("book plugin exit")
    require("update.init").onDestroy()
    require("remote.init").onDestroy()
    desktopLife(self, "onDestroy")
    logger.flush()
end

--- 网络恢复：重试脏数据、通知源、刷新锁屏。
---@return nil
function BookPlugin:onNetworkConnected()
    logger.info("book lifecycle network_connected")
    require("book.sync").retryDirtyAsync()
    self:emitToSource("network_connected")
    require("lockscreen.init").refresh(nil, true, "network_connected")
    desktopLife(self, "onNetworkConnected")
end

--- 翻页（分页视图）：统计换页；分发 page_changed
---@param page number
---@return nil
function BookPlugin:onPageUpdate(page)
    logger.dbg("book lifecycle page_update", page)
    require("ui.reader.session").onPageChanged(self, page)
end

--- 翻页（滚动视图）：统计换页；分发 page_changed
---@param _pos any
---@param page number|nil
---@return nil
function BookPlugin:onPosUpdate(_pos, page)
    logger.dbg("book lifecycle pos_update", page)
    require("ui.reader.session").onPageChanged(self, page)
end

--- 注解变化：由阅读会话按当前身份持久化。
---@param items table KOReader 变更描述
function BookPlugin:onAnnotationsModified(items)
    logger.dbg("book lifecycle annotations_modified", #items)
    require("ui.reader.session").onAnnotationsModified(self, items)
end

-- ── 对外动作（桌面 / 设置页调用）───────────────────────

--- 当前活跃数据源（经 SourceRegistry；失败返回 nil）
---@return BookSource|nil
function BookPlugin:getSource()
    return SourceRegistry.current()
end

--- 向源转发生命周期事件；源实现抛错只记日志，不阻断阅读主流程。
---@param event string
---@param payload table|nil
---@param source BookSource|nil 指定属主源；缺省取当前活跃源
---@return nil
function BookPlugin:emitToSource(event, payload, source)
    source = source or self:getSource()
    if not source then
        logger.dbg("book source event skipped:", event)
        return
    end
    logger.dbg("book source event:", event, source.id)
    local ok, err = pcall(source.onEvent, source, event, payload)
    if not ok then
        logger.error("book source event failed:", event, err)
    end
end

--- 下载（如需）并打开书籍
---@param book Book
---@return nil
function BookPlugin:openBook(book)
    Open.book(self, book)
end

--- 数据源切换后：通知桌面并让新源做桌面打开维护。
---@return nil
function BookPlugin:onSourceChanged()
    local source = SourceRegistry.current()
    logger.info("book source changed", source and source.id or "unavailable")
    desktopLife(self, "onEvent", "source_changed", source)
    if self.desktop and source then
        self:emitToSource("desktop_open", self.desktop, source)
    end
end

--- 打开月读全屏桌面
---@return nil
function BookPlugin:openDesktop()
    -- 阅读中桌面宿主是 FileManager 实例：先退出阅读面板，再委托 FM 打开，
    -- 避免把全屏桌面叠在未关闭的阅读器上。
    local from_reader = self.ui and self.ui.document
    if from_reader then
        if self.ui.onClose then self.ui:onClose() end
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        if ok and FileManager then
            if not FileManager.instance then FileManager:showFiles() end
            local fm = FileManager.instance
            local fm_plugin = fm and fm.book
            if fm_plugin and type(fm_plugin.openDesktop) == "function" then
                fm_plugin:openDesktop()
            end
        end
        return
    end

    local source = SourceRegistry.current()
    if not source then
        UIManager:show(InfoMessage:new{ text = _("当前数据源不可用") })
        return
    end
    require("utils.paths").ensureLayout(source.id)
    logger.info("book openDesktop", source.id)
    if self.desktop then
        local old = self.desktop
        desktopLife(self, "onDestroy")
        UIManager:close(old)
        self.desktop = nil
    end

    logger.info("book openDesktop create desktop begin")
    local ok, desk = pcall(function()
        return Desktop:new {
            plugin = self,
            source = source,
        }
    end)
    logger.info("book openDesktop create desktop end", ok and "ok" or "failed")
    if not ok then
        logger.error("book desktop create failed:", desk)
        UIManager:show(InfoMessage:new {
            text = _("桌面打开失败:\n") .. tostring(desk),
        })
        return
    end
    ---@cast desk BookDesktop
    self.desktop = desk
    logger.info("book openDesktop show begin")
    UIManager:show(self.desktop)
    logger.info("book openDesktop show end")
    UIManager:setDirty(self.desktop, "ui")
    logger.info("book openDesktop onResume begin")
    desktopLife(self, "onResume")
    logger.info("book openDesktop onResume end")
    -- 桌面已可见；源可后台做书架/统计维护（先读本地，成功后再刷新）。
    self:emitToSource("desktop_open", self.desktop, source)
end

return BookPlugin
