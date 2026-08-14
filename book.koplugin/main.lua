--[[--
Book 书库插件入口 — 事件接线板。

KOReader 会为 FileManager 和 Reader 各建一个插件实例；
关书后 FM 侧实例才是开桌面的宿主。

@module koplugin.book
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
require("l10n")
local _ = require("gettext")

local SourceRegistry = require("source.registry")
local Desktop = require("ui.desktop")
local ReaderFloatMenu = require("ui.readermenu")
local StatsSync = require("stats.stats_sync")
local Host = require("host")
local Progress = require("book.progress")
local Open = require("book.open")

--- Book 插件实例（FM / Reader 各一份）
---@class BookPlugin : WidgetContainer
---@field name string
---@field is_doc_only boolean
---@field ui table|nil KOReader UI（FileManager 或 ReaderUI）
---@field desktop table|nil 当前全屏桌面实例
---@field _reader_float_menu table|nil 阅读器悬浮菜单（由 readermenu 挂接）
local BookPlugin = WidgetContainer:extend {
    name = "book",
    is_doc_only = false,
}

-- ── 生命周期事件 ─────────────────────────────────────

--- 插件初始化：挂接 Host（菜单 / 开机打开等）
---@return nil
function BookPlugin:init()
    local ok, err = pcall(function()
        Host.attach(self)
    end)
    if not ok then
        logger.err("book plugin init failed:", err)
    end
end

--- FM 显示时同步接管（避免 FileManager 先闪一帧）
---@return nil
function BookPlugin:onShow()
    Host.onShow(self)
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

--- 阅读器就绪：挂悬浮菜单；拉进度 / 注册统计设备
---@return nil
function BookPlugin:onReaderReady()
    ReaderFloatMenu.attach(self)
    Progress.pull(self.ui, self:getSource(), false)
    NetworkMgr:runWhenOnline(function()
        StatsSync.registerDevice(self:getSource())
    end)
end

--- 屏幕尺寸变化：重新挂接悬浮菜单（旋转 / 分栏等）
---@return nil
function BookPlugin:onSetDimensions()
    ReaderFloatMenu.attach(self)
end

--- 关文档：卸悬浮菜单；推进度 / 上报统计；清按章会话
---@return nil
function BookPlugin:onCloseDocument()
    ReaderFloatMenu.detach(self)
    Progress.push(self.ui, self:getSource(), false)
    StatsSync.pushWithUi(self:getSource(), false, false)
    local ok, Chapter = pcall(require, "book.chapter")
    if ok and Chapter and Chapter.clear then
        Chapter.clear()
    end
end

--- 休眠前：有打开文档时推进度 / 上报统计
---@return nil
function BookPlugin:onSuspend()
    if not self.ui.document then
        return
    end
    Progress.push(self.ui, self:getSource(), false)
    StatsSync.pushWithUi(self:getSource(), false, false)
end

-- ── 对外动作（UI / 设置页调用）───────────────────────

--- 当前活跃数据源（经 SourceRegistry；失败返回 nil）
---@return BookSource|nil
function BookPlugin:getSource()
    return SourceRegistry.current()
end

--- 下载（如需）并打开书籍
---@param book Book
---@return nil
function BookPlugin:openBook(book)
    Open.book(self, book, self:getSource())
end

--- 上报阅读统计
---@param show_msg boolean|nil 是否向用户弹进度/结果
---@param force boolean|nil 忽略节流与「自动上报」开关
---@return nil
function BookPlugin:pushReadingStats(show_msg, force)
    local source = self:getSource()
    if not source then
        return
    end
    local caps = source:capabilities() or {}
    if not caps.stats_import then
        return
    end
    StatsSync.pushWithUi(source, show_msg, force)
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
    if not self.desktop then
        return
    end
    local desk = self.desktop
    desk.source_generation = (desk.source_generation or 0) + 1
    if desk._home_fetch_cancel then pcall(desk._home_fetch_cancel) end
    if desk._library_fetch_cancel then pcall(desk._library_fetch_cancel) end
    if desk._store_fetch_cancel then pcall(desk._store_fetch_cancel) end
    if desk._insight_fetch_cancel then pcall(desk._insight_fetch_cancel) end
    local Image = require("ui.components.image")
    if Image.abortPending then
        pcall(Image.abortPending)
    end
    desk.source = source
    desk._home_state = nil
    desk._home_loaded = false
    desk._library_state = nil
    desk._store_state = nil
    desk._insight_state = nil
    desk._insight_loaded = false
    desk.filter = nil
    local caps = source and source:capabilities() or {}
    if desk.tab == "store" and not caps.store then
        desk.tab = "home"
    end
    if desk.tab == "stats" and not caps.insight then
        desk.tab = "home"
    end
    desk:rebuild()
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
    UIManager:setDirty(self.desktop, "full")
end

return BookPlugin
