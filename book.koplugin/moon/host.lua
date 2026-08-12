--[[--
KOReader 宿主钩子：FileManager + 启动项 + 设置菜单置顶。

@module koplugin.book.moon.host
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local MoonSettings = require("moon.settings")
local _ = require("gettext")

local Host = {}

Host.START_WITH_ID = "bookshelf_book"
local MENU_ITEM_ID = "book_library"

local pending_open_desktop = false

function Host.setPending(on)
    pending_open_desktop = on and true or false
end

function Host.takePending()
    local v = pending_open_desktop
    pending_open_desktop = false
    return v
end

function Host.applyStartWith()
    local s = MoonSettings.get()
    if s.open_on_start == false then
        return false
    end
    if G_reader_settings:readSetting("start_with") ~= Host.START_WITH_ID then
        G_reader_settings:saveSetting("start_with", Host.START_WITH_ID)
    end
    return true
end

function Host.isStartWith()
    local s = MoonSettings.get()
    if s.open_on_start == false then
        return false
    end
    return G_reader_settings:readSetting("start_with", "filemanager") == Host.START_WITH_ID
end

function Host.openFromFileManager(fallback_plugin)
    local ok_pl, PluginLoader = pcall(require, "pluginloader")
    if ok_pl and PluginLoader and PluginLoader.getPluginInstance then
        local book = PluginLoader:getPluginInstance("book")
        if book and book.openDesktop then
            book:openDesktop()
            return true
        end
    end
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager and FileManager.instance
    local book = fm and fm.book
    if book and book.openDesktop then
        book:openDesktop()
        return true
    end
    if fm then
        for _, child in ipairs(fm) do
            if type(child) == "table" and child.name == "book" and child.openDesktop then
                child:openDesktop()
                return true
            end
        end
    end
    if fallback_plugin and fallback_plugin.openDesktop and fallback_plugin.ui
        and fallback_plugin.ui.file_chooser then
        fallback_plugin:openDesktop()
        return true
    end
    return false
end

local function wrapFmOnShow(plugin, fm)
    if not fm or fm._book_onshow_wrapped then
        return
    end
    fm._book_onshow_wrapped = true
    local orig_onShow = fm.onShow
    fm.onShow = function(this)
        if orig_onShow then
            orig_onShow(this)
        end
        if this._book_autoopen_pending then
            this._book_autoopen_pending = nil
            UIManager:scheduleIn(0, function()
                if plugin and plugin.openDesktop and not plugin.desktop then
                    plugin:openDesktop()
                end
            end)
        end
        if pending_open_desktop then
            pending_open_desktop = false
            UIManager:scheduleIn(0, function()
                if not Host.openFromFileManager(plugin) then
                    logger.warn("book pending desktop open failed")
                end
            end)
        end
    end
end

function Host.watchFileManager(plugin)
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager and FileManager.instance then
        wrapFmOnShow(plugin, FileManager.instance)
    end
end

function Host.requestDesktopOpen(plugin, fm)
    if not Host.isStartWith() then
        return
    end
    if fm then
        fm._book_autoopen_pending = true
        wrapFmOnShow(plugin, fm)
    end
    UIManager:scheduleIn(0.25, function()
        if plugin and plugin.openDesktop and not plugin.desktop then
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            local live = ok and FileManager and FileManager.instance
            if (plugin.ui and plugin.ui.file_chooser) or live then
                plugin:openDesktop()
            end
        end
    end)
end

local function patchFileManager(plugin)
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then
        return
    end

    if not FileManager._book_plugin_patched then
        FileManager._book_plugin_patched = true

        local orig_setup = FileManager.setupLayout
        FileManager.setupLayout = function(fm_self)
            orig_setup(fm_self)
            wrapFmOnShow(plugin, fm_self)
            if not FileManager._book_boot_done then
                FileManager._book_boot_done = true
                if Host.isStartWith() then
                    fm_self._book_autoopen_pending = true
                end
            end
        end

        if FileManager.getPlusDialogButtons and not FileManager._book_plus_patched then
            FileManager._book_plus_patched = true
            local orig_plus = FileManager.getPlusDialogButtons
            FileManager.getPlusDialogButtons = function(fm)
                local title, buttons = orig_plus(fm)
                table.insert(buttons, 1, {{
                    text = _("Book 桌面"),
                    callback = function()
                        UIManager:close(fm.plus_dialog)
                        plugin:openDesktop()
                    end,
                }})
                return title, buttons
            end
        end
    end

    if FileManager.instance then
        wrapFmOnShow(plugin, FileManager.instance)
        Host.requestDesktopOpen(plugin, FileManager.instance)
    end
end

local function patchStartWithMenu()
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu or not FMMenu.getStartWithMenuTable then
        return
    end
    if FMMenu._book_startwith_patched then
        return
    end
    FMMenu._book_startwith_patched = true
    local orig = FMMenu.getStartWithMenuTable
    FMMenu.getStartWithMenuTable = function(self)
        local item = orig(self)
        if item and item.sub_item_table then
            local already = false
            for _, row in ipairs(item.sub_item_table) do
                if row._book_startwith_item then
                    already = true
                    break
                end
            end
            if not already then
                table.insert(item.sub_item_table, 1, {
                    _book_startwith_item = true,
                    text = _("Book 书库"),
                    checked_func = function()
                        return G_reader_settings:readSetting("start_with") == Host.START_WITH_ID
                    end,
                    callback = function()
                        G_reader_settings:saveSetting("start_with", Host.START_WITH_ID)
                        local s = MoonSettings.get()
                        s.open_on_start = true
                        MoonSettings.save(s)
                    end,
                    radio = true,
                })
                for _, row in ipairs(item.sub_item_table) do
                    if not row._book_startwith_item and row.callback and not row._book_startwith_wrapped then
                        row._book_startwith_wrapped = true
                        local prev = row.callback
                        row.callback = function(...)
                            local s = MoonSettings.get()
                            s.open_on_start = false
                            MoonSettings.save(s)
                            return prev(...)
                        end
                    end
                end
            end
        end
        return item
    end
end

local function pinBookInSettingsMenu()
    for _, modname in ipairs({
        "ui/elements/filemanager_menu_order",
        "ui/elements/reader_menu_order",
    }) do
        local ok, order = pcall(require, modname)
        if ok and type(order) == "table" and type(order.setting) == "table" then
            for i = #order.setting, 1, -1 do
                if order.setting[i] == MENU_ITEM_ID then
                    table.remove(order.setting, i)
                end
            end
            table.insert(order.setting, 1, MENU_ITEM_ID)
        end
    end
end

function Host.install(plugin)
    pinBookInSettingsMenu()
    patchFileManager(plugin)
    patchStartWithMenu()
    if plugin.ui and plugin.ui.file_chooser then
        Host.requestDesktopOpen(plugin, plugin.ui)
    end
    if pending_open_desktop and plugin.ui and plugin.ui.file_chooser then
        pending_open_desktop = false
        UIManager:scheduleIn(0.2, function()
            if plugin and plugin.openDesktop and not plugin.desktop then
                plugin:openDesktop()
            end
        end)
    end
end

return Host
