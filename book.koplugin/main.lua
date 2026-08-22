--[[--
Book 书库插件入口 — 事件接线板。

KOReader 会为 FileManager 和 Reader 各建一个插件实例；
关书后 FM 侧实例才是开桌面的宿主。

@module koplugin.book
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
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
    -- HTTP 依赖 Turbo ioloop；必须在 UIManager:run() 前打开 DUSE_TURBO_LIB
    local ok_turbo, err_turbo = pcall(function()
        require("http.request").ensureTurbo()
    end)
    if not ok_turbo then
        logger.err("book turbo init failed:", err_turbo)
    end
    Host.attach(self)
    require("translate.init").install()
    require("ui.desktop.panel.native").install(self.ui)
    require("lockscreen.init").bootstrap()
    require("remote.init").bootstrap()
    require("pinyin.init").bootstrap()
    -- Reader 扫描 styletweaks 前落盘，保证全局阅读风格 CSS 可被注册
    pcall(function()
        require("ui.reader.layout").ensureCssFile()
    end)
    if self.ui and self.ui.document then
        self:emitToSource("reader_open")
    end
end

--- FM 显示时同步接管（避免 FileManager 先闪一帧）
---@return nil
function BookPlugin:onShow()
    Host.onShow(self)
    if self.ui and not self.ui.document then
        self:emitToSource("fm_open")
    end
end

--- Dispatcher / 手势：打开 Book 桌面
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
        text = _("Book 桌面"),
        sorting_hint = "setting",
        callback = function()
            self:openDesktop()
        end,
    }
end

--- 阅读器就绪：建阅读会话；统计计时；拉进度；按章落点；挂阅读页
---@return nil
function BookPlugin:onReaderReady()
    require("ui.reader.session").onReaderReady(self)
end

--- 关文档：推进度；结清统计；通知源；切章则保留会话，真关书才清
---@return nil
function BookPlugin:onCloseDocument()
    require("ui.reader.session").onCloseDocument(self)
end

--- 章末：按章会话自动下一章
---@return boolean
function BookPlugin:onEndOfBook()
    return require("ui.reader.session").onChapterBoundary(1)
end

--- 章首：按章会话自动上一章（由阅读会话边界处理触发）
---@return boolean
function BookPlugin:onStartOfBook()
    return require("ui.reader.session").onChapterBoundary(-1)
end

--- 休眠前：有打开文档时推进度 / 结清统计并通知源；远程传书停服（resume 恢复）
---@return nil
function BookPlugin:onSuspend()
    require("ui.reader.session").onSuspend(self)
    require("remote.init").onSuspend()
end

--- 唤醒：恢复阅读统计计时；预生成下一次锁屏；恢复远程传书
---@return nil
function BookPlugin:onResume()
    require("ui.reader.session").onResume(self)
    require("lockscreen.init").onResume()
    require("remote.init").onResume()
end

--- 退出：停远程传书服务
---@return nil
function BookPlugin:onExit()
    require("remote.init").onExit()
end

--- 网络恢复：通知当前源重试持久化队列，并刷新锁屏图。
---@return nil
function BookPlugin:onNetworkConnected()
    require("book.sync").retryDirtyAsync()
    self:emitToSource("network_connected")
    require("lockscreen.init").refreshInBackground(true)
end

--- 翻页（分页视图）：统计换页；分发 page_changed
---@param page number
---@return nil
function BookPlugin:onPageUpdate(page)
    require("ui.reader.session").onPageChanged(self, page)
end

--- 翻页（滚动视图）：统计换页；分发 page_changed
---@param _pos any
---@param page number|nil
---@return nil
function BookPlugin:onPosUpdate(_pos, page)
    require("ui.reader.session").onPageChanged(self, page)
end

--- 注解变化：由阅读会话按当前身份持久化，并预生成高亮锁屏。
---@param items table KOReader 变更描述
function BookPlugin:onAnnotationsModified(items)
    require("ui.reader.session").onAnnotationsModified(self, items)
    require("lockscreen.init").onAnnotationsModified()
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
        return
    end
    local ok, err = pcall(source.onEvent, source, event, payload)
    if not ok then
        logger.err("book source event failed:", event, err)
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
    logger.info("book onSourceChanged")
    local source = SourceRegistry.current()
    if source and source.clearCaches then
        source:clearCaches()
    end
    if self.desktop then
        self.desktop:sourceChanged(source)
        self:emitToSource("desktop_open", self.desktop, source)
    end
end

--- 打开全屏 Book 桌面
---@param filter table|nil 图书馆初始筛选（透传 Desktop.filter）
---@return nil
function BookPlugin:openDesktop(filter)
    local source = self:getSource()
    if not source then
        UIManager:show(InfoMessage:new{ text = _("当前数据源不可用") })
        return
    end
    require("utils.paths").ensureLayout(source.id)
    require("utils.paths").ensureLayout("image") -- 网络图缓存命名空间（非书源）
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
        logger.err("book desktop create failed:", desk)
        UIManager:show(InfoMessage:new {
            text = _("桌面打开失败:\n") .. tostring(desk),
        })
        return
    end
    self.desktop = desk
    UIManager:show(self.desktop)
    UIManager:setDirty(self.desktop, "ui")
    -- 桌面已可见；源可趁后台做自动维护（本地源：扫描写库 + 清失效）
    self:emitToSource("desktop_open", self.desktop)
end

return BookPlugin
