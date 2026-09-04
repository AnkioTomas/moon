--[[--
月读插件入口 — 事件接线板。

KOReader 会为 FileManager 和 Reader 各建一个插件实例；
关书后 FM 侧实例才是开桌面的宿主。

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

--- Book 插件实例（FM / Reader 各一份）
---@class BookPlugin : WidgetContainer
---@field name string
---@field is_doc_only boolean
---@field ui table|nil KOReader UI（FileManager 或 ReaderUI）
---@field desktop table|nil 当前全屏桌面实例
local BookPlugin = WidgetContainer:extend {
    name = "book",
    is_doc_only = false,
}

-- ── 生命周期事件 ─────────────────────────────────────

--- 插件初始化：挂接 Host（菜单 / 开机打开等）
---@return nil
function BookPlugin:init()
    logger.start()
    logger.info("book plugin init", self.ui and self.ui.document and "reader" or "filemanager")
    -- HTTP 依赖 Turbo ioloop；必须在 UIManager:run() 前打开 DUSE_TURBO_LIB
    local ok_turbo, err_turbo = pcall(function()
        require("http.request").ensureTurbo()
    end)
    if not ok_turbo then
        logger.error("book turbo init failed:", err_turbo)
    end
    Host.attach(self)
    -- ReaderLink 已原生处理脚注识别、内容提取和弹窗跳转。升级后的第一次
    -- 初始化也要打开一次，之后用户可在「链接」菜单关闭，月读不再覆盖选择。
    if G_reader_settings and not G_reader_settings:isTrue("book_footnote_popup_initialized") then
        G_reader_settings:saveSetting("footnote_link_in_popup", true)
        G_reader_settings:saveSetting("book_footnote_popup_initialized", true)
    end
    require("translate.init").install()
    require("baike.init").install()
    require("dictionary.init").install()
    require("ui.panel.native").install(self.ui)
    require("lockscreen.init").bootstrap()
    require("remote.init").bootstrap()
    -- ButtonDialog 依赖设备后端；离线加载插件时该后端不存在，不能让无关功能整个失效。
    local ok_share, err_share = pcall(function() require("ui.screenshot_share").install() end)
    if not ok_share then
        logger.warn("book screenshot share install failed:", err_share)
    end
    require("pinyin.init").bootstrap()
    require("patch.manager").init({ plugin_root = self.path })
    UIManager:nextTick(function()
        local ok_animation, err_animation = pcall(function()
            require("patch.page_turn_animation").checkStartup()
        end)
        if not ok_animation then
            logger.warn("book page turn animation check failed:", err_animation)
        end
    end)
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
---@return nil
function BookPlugin:onDocSettingsLoad(doc_settings)
    logger.dbg("book lifecycle doc_settings_load")
    require("book.reader_prefs").inject(doc_settings, self.document)
end

--- 阅读器就绪：建阅读会话；统计计时；拉进度；按章落点；挂阅读页
---@return nil
function BookPlugin:onReaderReady()
    logger.info("book lifecycle reader_ready")
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

--- 章首：按章会话自动上一章（由阅读会话边界处理触发）
---@return boolean
function BookPlugin:onStartOfBook()
    logger.dbg("book lifecycle start_of_book")
    return require("ui.reader.session").onChapterBoundary(-1)
end

--- 休眠前：结清阅读状态，生成下一次锁屏图，停远程传书服务。
---@return nil
function BookPlugin:onSuspend()
    logger.info("book lifecycle suspend")
    require("ui.reader.session").onSuspend(self)
    require("lockscreen.init").refresh(nil, true)
    require("remote.init").onSuspend()
end

--- 唤醒：恢复阅读统计计时与后台服务；月读桌面按当前页面刷新本地 UI 和源数据。
---@return nil
function BookPlugin:onResume()
    logger.info("book lifecycle resume")
    require("ui.reader.session").onResume(self)
    require("lockscreen.init").onResume()
    require("remote.init").onResume()
    local desktop = self.desktop
    if not desktop or desktop._closed then return end
    if desktop.tab == "home" then
        require("ui.desktop.home").refreshOnEnter(desktop)
    else
        self:emitToSource("desktop_resume", desktop)
    end
end

--- 退出：停远程传书服务
---@return nil
function BookPlugin:onExit()
    logger.info("book plugin exit")
    require("remote.init").onExit()
end

--- 网络恢复：通知当前源重试持久化队列，并刷新锁屏图。
---@return nil
function BookPlugin:onNetworkConnected()
    logger.info("book lifecycle network_connected")
    require("book.sync").retryDirtyAsync()
    self:emitToSource("network_connected")
    require("lockscreen.init").refresh(nil, true)
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

--- 注解变化：由阅读会话按当前身份持久化，并预生成高亮锁屏。
---@param items table KOReader 变更描述
function BookPlugin:onAnnotationsModified(items)
    logger.dbg("book lifecycle annotations_modified", #items)
    require("ui.reader.session").onAnnotationsModified(self, items)
end

-- ── 对外动作（UI / 设置页调用）───────────────────────

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

--- 数据源切换后：取消旧请求、回退 Tab、重建桌面
--- 注意：Registry.setActive 已原子激活新源，此处不再 invalidate。
---@return nil
function BookPlugin:onSourceChanged()
    local source = SourceRegistry.current()
    logger.info("book source changed", source and source.id or "unavailable")
    if source and source.clearCaches then
        source:clearCaches()
    end
    if self.desktop then
        self.desktop:sourceChanged(source)
        self:emitToSource("desktop_open", self.desktop, source)
    end
end

--- 打开月读全屏桌面
---@param filter table|nil 图书馆初始筛选（透传 Desktop.filter）
---@return nil
function BookPlugin:openDesktop(filter)
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
                fm_plugin._home_rotate_on_open = true
                fm_plugin:openDesktop(filter)
            end
        end
        return
    end

    local source = self:getSource()
    if not source then
        UIManager:show(InfoMessage:new{ text = _("当前数据源不可用") })
        return
    end
    require("utils.paths").ensureLayout(source.id)
    require("utils.paths").ensureImageRoot() -- 网络图缓存目录（非书源）
    logger.info("book openDesktop", source.id)
    if self.desktop then
        UIManager:close(self.desktop)
        self.desktop = nil
    end

    local ok, desk = pcall(function()
        return Desktop:new {
            plugin = self,
            source = source,
            filter = filter or {},
            tab = "home",
            covers_fullscreen = true,
            close_callback = function()
                self.desktop = nil
            end,
        }
    end)
    if not ok then
        logger.error("book desktop create failed:", desk)
        UIManager:show(InfoMessage:new {
            text = _("桌面打开失败:\n") .. tostring(desk),
        })
        return
    end
    self.desktop = desk
    if self._home_rotate_on_open then
        self._home_rotate_on_open = nil
        require("ui.desktop.home").onReturnToDesktop(desk)
    end
    UIManager:show(self.desktop)
    UIManager:setDirty(self.desktop, "ui")
    -- 桌面已可见；源可趁后台做自动维护（本地源：扫描写库 + 清失效）
    self:emitToSource("desktop_open", self.desktop)
end

return BookPlugin
