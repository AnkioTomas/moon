--[[--
月读插件入口 — 桌面接线板。

KOReader 会为 FileManager 和 Reader 各建一个插件实例；
关书后 FM 侧实例才是开桌面的宿主。

阅读 / 锁屏 / 远程等接线暂时拆出，残留模块不动。

@module koplugin.book
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("utils.log")
require("l10n")
local _ = require("gettext")


local MIN_KOREADER_VERSION = 202607010000

local function checkKOReaderVersion()
    local ok, Version = pcall(require, "version")
    local current = ok and Version and Version:getNormalizedCurrentVersion()
    if type(current) == "number" and current >= MIN_KOREADER_VERSION then
        return true
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    local display = ok and Version and Version.getShortVersion and Version:getShortVersion() or _("未知")
    UIManager:show(ConfirmBox:new {
        text = _("月读需要 KOReader 2026.07.1 或更高版本。\n\n当前版本：") .. tostring(display),
        ok_text = _("关闭"),
    })
    return false
end

local SourceRegistry = require("source.registry")
local Desktop = require("ui.desktop")
local Host = require("host")

--- 调用当前桌面方法（生命周期或 onEvent）。无桌面或已销毁则跳过。
--- 门槛是 Destroy，不是 Alive()：Pause/Stop 后还要能进 onStop / onDestroy / onResume。
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
local BookPlugin = WidgetContainer:extend {
    name = "book",
    is_doc_only = false,
}

-- ── 生命周期事件 ─────────────────────────────────────

--- 插件初始化：挂接 Host（菜单 / 开机打开等）
---@return nil
function BookPlugin:init()
    if not checkKOReaderVersion() then
        return
    end
    logger.start()
    logger.info("book plugin init", self.ui and self.ui.document and "reader" or "filemanager")
    Host.attach(self)
end

--- FM 显示时同步接管（避免 FileManager 先闪一帧）
---@return nil
function BookPlugin:onShow()
    logger.dbg("book lifecycle show")
    Host.onShow(self)
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

--- 休眠：桌面走 onPause → onStop。
---@return nil
function BookPlugin:onSuspend()
    logger.info("book lifecycle suspend")
    desktopLife(self, "onPause")
    desktopLife(self, "onStop")
    logger.flush()
end

--- 唤醒：桌面在窗口栈上，自己收 KOReader 的 Resume。这里不再转一次。
---@return nil
function BookPlugin:onResume()
    logger.info("book lifecycle resume")
end

--- 退出：销毁仍打开的桌面。
---@return nil
function BookPlugin:onExit()
    logger.info("book plugin exit")
    desktopLife(self, "onDestroy")
    logger.flush()
end

-- ── 对外动作（桌面 / 设置页调用）───────────────────────

--- 数据源切换后：只通知当前桌面，不向源转发事件。
---@return nil
function BookPlugin:onSourceChanged()
    local source = SourceRegistry.current()
    logger.info("book source changed", source and source.id or "unavailable")
    desktopLife(self, "onEvent", "source_changed", source)
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
                fm_plugin._home_rotate_on_open = true
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
        desktopLife(self, "onPause")
        desktopLife(self, "onStop")
        desktopLife(self, "onDestroy")
        UIManager:close(old)
        self.desktop = nil
    end

    local ok, desk = pcall(function()
        return Desktop:new {
            plugin = self,
            source = source,
        }
    end)
    if not ok then
        logger.error("book desktop create failed:", desk)
        UIManager:show(InfoMessage:new {
            text = _("桌面打开失败:\n") .. tostring(desk),
        })
        return
    end
    ---@cast desk BookDesktop
    self.desktop = desk
    UIManager:show(self.desktop)
    UIManager:setDirty(self.desktop, "ui")
    desktopLife(self, "onStart")
    desktopLife(self, "onResume")
end

return BookPlugin
