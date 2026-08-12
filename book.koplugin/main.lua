--[[--
Book 书库插件入口 — 事件接线板。

KOReader 会为 FileManager 和 Reader 各建一个插件实例；
关书后 FM 侧实例才是开桌面的宿主。

@module koplugin.book
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Dispatcher = require("dispatcher")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
require("l10n")
local _ = require("gettext")

local SourceRegistry = require("source.registry")
local Desktop = require("ui.desktop")
local ReaderFloatMenu = require("ui.readermenu")
local StatsSync = require("stats_sync")
local MoonSettings = require("moon.settings")
local Host = require("moon.host")
local Progress = require("moon.progress")
local Open = require("moon.open")

local BookPlugin = WidgetContainer:extend {
    name = "book",
    is_doc_only = false,
}

-- ── 生命周期事件 ─────────────────────────────────────

function BookPlugin:init()
    local ok, err = pcall(function()
        self:tryRegisterMenu()
        Host.attach(self)
    end)
    if not ok then
        logger.err("book plugin init failed:", err)
    end
end

--- FM 显示时同步接管（避免 FileManager 先闪一帧）
function BookPlugin:onShow()
    Host.onShow(self)
end

function BookPlugin:tryRegisterMenu()
    Dispatcher:registerAction("book_open_shelf", {
        category = "none",
        event = "BookOpenShelf",
        title = _("打开 Book 桌面"),
        general = true,
        filemanager = true,
    })

    if self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function BookPlugin:onBookOpenShelf()
    self:openDesktop()
    return true
end

function BookPlugin:addToMainMenu(menu_items)
    menu_items.book_library = {
        text = _("Book 桌面"),
        sorting_hint = "setting",
        callback = function()
            self:openDesktop()
        end,
    }
end

function BookPlugin:onReaderReady()
    ReaderFloatMenu.attach(self)
    local s = MoonSettings.get()
    if s.auto_sync then
        Progress.pull(self.ui, self:getSource(), false)
    end
    if s.auto_stats ~= false then
        NetworkMgr:runWhenOnline(function()
            StatsSync.registerDevice(self:getSource())
        end)
    end
end

function BookPlugin:onSetDimensions()
    ReaderFloatMenu.attach(self)
end

function BookPlugin:onCloseDocument()
    ReaderFloatMenu.detach(self)
    local s = MoonSettings.get()
    if s.auto_sync then
        Progress.push(self.ui, self:getSource(), false)
    end
    if s.auto_stats ~= false then
        StatsSync.pushWithUi(self:getSource(), false, false)
    end
end

function BookPlugin:onSuspend()
    if not self.ui.document then
        return
    end
    local s = MoonSettings.get()
    if s.auto_sync then
        Progress.push(self.ui, self:getSource(), false)
    end
    if s.auto_stats ~= false then
        StatsSync.pushWithUi(self:getSource(), false, false)
    end
end

-- ── 对外动作（UI / 设置页调用）───────────────────────

function BookPlugin:getSource()
    return SourceRegistry.getActive()
end

function BookPlugin:openBook(book)
    Open.book(self, book)
end

function BookPlugin:pushReadingStats(show_msg, force)
    StatsSync.pushWithUi(self:getSource(), show_msg, force)
end

function BookPlugin:onSourceChanged()
    SourceRegistry.invalidate()
    local source = self:getSource()
    if source and source.clearCaches then
        source:clearCaches()
    end
    if not self.desktop then
        return
    end
    self.desktop.source = source
    self.desktop._home_state = nil
    self.desktop._home_loaded = false
    self.desktop._library_state = nil
    self.desktop._store_state = nil
    self.desktop._insight_state = nil
    self.desktop._insight_loaded = false
    local caps = source:capabilities() or {}
    if self.desktop.tab == "store" and not caps.store then
        self.desktop.tab = "home"
    end
    self.desktop:rebuild()
end

function BookPlugin:openDesktop(filter)
    local source = self:getSource()
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
