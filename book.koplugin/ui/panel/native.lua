--[[--
将 Book 快捷面板融入 KOReader 原生顶部菜单。

桌面与阅读页各注入独立 Tab；TouchMenu 内容渲染统一在此 patch，
保留原生遮罩、Tab 栏分割线与页脚。

@module koplugin.book.ui.panel.native
--]]

require("l10n").apply()

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Menu = require("ui.panel.menu")
local NativeSettings = require("ui.panel.native_settings")

---@class BookQuickPanelNative
---@field show fun(mode: "desktop"|"reader"|nil): boolean
---@field install fun(host_ui: table|nil, opts: table|nil): void

local Native = {}

local DESKTOP_MARKER = "_book_quick_panel"
local READER_MARKER = "_book_reader_panel"
local DESKTOP_TAB_ICON = "appbar.pokeball"
local READER_TAB_ICON = "appbar.pageview"

--- 组装面板动作用的关闭/刷新回调。
---@param menu table
---@return BookQuickPanelExecuteOpts
local function menuCallbacks(menu)
    return {
        close = function() Menu.close(menu) end,
        refresh = function() Menu.refresh(menu) end,
    }
end

--- 根据 Tab 标记判断当前面板模式。
---@param item_table table|nil
---@return "desktop"|"reader"|nil
local function panelMode(item_table)
    if item_table and item_table[DESKTOP_MARKER] then return "desktop" end
    if item_table and item_table[READER_MARKER] then return "reader" end
end

---@type BookQuickPanelWidgets|nil
local Widgets

---@class BookQuickPanelWidgets
---@field Blitbuffer table
---@field FrameContainer table
---@field Geom table
---@field UI table
---@field Body BookQuickPanelBody
---@field Header BookQuickPanelHeader
---@field Desktop table
---@field ReaderPanel table

--- 延迟加载并缓存面板自绘所需的 UI 模块。
---@return BookQuickPanelWidgets
local function ensureWidgets()
    if Widgets then return Widgets end
    Widgets = {
        Blitbuffer = require("ffi/blitbuffer"),
        FrameContainer = require("ui/widget/container/framecontainer"),
        Geom = require("ui/geometry"),
        UI = require("ui.components.bookui"),
        VerticalSpan = require("ui/widget/verticalspan"),
        Body = require("ui.panel.widget.body"),
        Header = require("ui.panel.widget.header"),
        Desktop = require("ui.panel.desktop"),
        ReaderPanel = require("ui.panel.reader"),
    }
    return Widgets
end

--- 关闭文档后回到 Book 桌面，而不是 KOReader 原生文件管理器。
---@return nil
local function openBookDesktop()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then return end
    -- 打开书时 ReaderUI 会关掉 FileManager；这里先重建，否则关闭文档后窗口栈为空直接退出。
    if not FileManager.instance then
        FileManager:showFiles()
    end
    local fm = FileManager.instance
    local plugin = fm and fm.book
    if plugin and type(plugin.openDesktop) == "function" then
        plugin:openDesktop()
    end
end

--- 退出阅读会话并回到 Book 桌面。
---@param ui table|nil
---@param menu table|nil
---@return nil
local function exitReading(ui, menu)
    Menu.close(menu)
    if ui and ui.onClose then ui:onClose() end
    openBookDesktop()
end

--- 用白底 FrameContainer 包裹面板主体。
---@param body table
---@param W BookQuickPanelWidgets
---@param width number
---@param pad number
---@return table
local function wrapPanel(body, W, width, pad)
    local height = pad * 2 + body:getSize().h
    return W.FrameContainer:new{
        bordersize = 0,
        padding = pad,
        background = W.Blitbuffer.COLOR_WHITE,
        width = width,
        height = height,
        dimen = W.Geom:new{ w = width, h = height },
        body,
    }
end

--- 按面板模式构建面板主体内容。
---@param menu table
---@param W BookQuickPanelWidgets
---@return table
local function buildPanel(menu, W)
    local tab = menu.item_table
    local mode = panelMode(tab)
    local width, pad = menu.item_width, W.UI.sz(8)
    local content_w = width - pad * 2
    local callbacks = menuCallbacks(menu)
    local body_opts = {
        width = content_w,
        on_action = function(id)
            if mode == "reader" then
                W.ReaderPanel.executeAction(id, tab._book_ui, callbacks)
            else
                W.Desktop.executeAction(id, callbacks)
            end
        end,
    }
    if mode == "reader" then
        local ui = tab._book_ui
        body_opts.header = W.Header:new{
            width = content_w,
            height = W.UI.sz(52),
            ui = ui,
            on_exit = function() exitReading(ui, menu) end,
        }
        body_opts.actions = W.ReaderPanel.actions(ui)
    else
        body_opts.actions = W.Desktop.menuActions()
        body_opts.sliders = W.Desktop.sliders()
        body_opts.on_level = function(kind, fraction)
            return W.Desktop.setLevel(kind, fraction)
        end
    end
    return wrapPanel(W.Body:new(body_opts), W, width, pad)
end

--- 临时 noop switchMenuTab 后触发 tab.callback，让 Tab 栏分割线按当前内容重算。
---@param menu table
---@return nil
local function syncBarSeparator(menu)
    local k = menu.cur_tab
    local ib = menu.bar and menu.bar.icon_widgets and k and menu.bar.icon_widgets[k]
    if not ib or not ib.callback then return end
    local original_switch = menu.switchMenuTab
    menu.switchMenuTab = function() end
    local ok, err = pcall(ib.callback)
    menu.switchMenuTab = original_switch
    if not ok then error(err, 0) end
end

--- 替换 TouchMenu 的 item 列表为 Book 面板自绘内容。
---@param menu table
---@return nil
local function renderPanelContent(menu)
    local W = ensureWidgets()
    syncBarSeparator(menu)
    menu.page, menu.page_num = 1, 1
    menu.item_group:clear()
    menu.layout = {}
    table.insert(menu.item_group, menu.bar)
    table.insert(menu.layout, menu.bar.icon_widgets)
    -- 面板自绘内容从 Tab 栏下移一点，避免贴顶。
    table.insert(menu.item_group, W.VerticalSpan:new{ width = W.UI.sz(16) })
    table.insert(menu.item_group, buildPanel(menu, W))
    table.insert(menu.item_group, menu.footer_top_margin)
    table.insert(menu.item_group, menu.footer)
    menu.page_info_text:setText("")
    menu.page_info_left_chev:showHide(false)
    menu.page_info_right_chev:showHide(false)
    local old_dimen = menu.dimen:copy()
    menu.dimen.w = menu.width
    menu.dimen.h = menu.item_group:getSize().h + menu.bordersize * 2 + menu.padding
    UIManager:setDirty((menu.is_fresh or menu.dimen.h >= old_dimen.h) and menu.show_parent or "all",
        function()
            local dimen = old_dimen:combine(menu.dimen)
            local refresh = menu.is_fresh and "flashui" or "ui"
            menu.is_fresh = false
            return refresh, dimen
        end)
end

--- 一次性 patch TouchMenu.updateItems，触屏设备命中面板 Tab 时改走自绘渲染。
---@return nil
local function patchTouchMenu()
    local ok, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not ok or TouchMenu._book_panel_patched then return end
    TouchMenu._book_panel_patched = true
    local original = TouchMenu.updateItems
    TouchMenu.updateItems = function(self, ...)
        if panelMode(self.item_table) and Device:isTouchDevice() then
            return renderPanelContent(self)
        end
        return original(self, ...)
    end
end

--- 把动作列表写入原生 Tab 的 item 数组。
---@param tab table
---@param actions table[]
---@param on_execute fun(id: string, menu: table)
---@return nil
local function populateTab(tab, actions, on_execute)
    -- 触屏设备走 renderPanelContent 自绘，不必填充原生 menu item。
    if Device:isTouchDevice() then return end
    for i = #tab, 1, -1 do table.remove(tab, i) end
    for _, action in ipairs(actions) do
        local id = action.id
        tab[#tab + 1] = {
            text = action.title,
            keep_menu_open = true,
            callback = function(menu) on_execute(id, menu) end,
        }
    end
end

--- 用桌面动作填充原生 Tab。
---@param tab table
---@return nil
local function populateDesktop(tab)
    local Panel = require("ui.panel.desktop")
    populateTab(tab, Panel.menuActions(), function(id, menu)
        Panel.executeAction(id, menuCallbacks(menu))
    end)
end

--- 用阅读动作填充原生 Tab。
---@param tab table
---@return nil
local function populateReader(tab)
    local ReaderPanel = require("ui.panel.reader")
    local ui = tab._book_ui
    populateTab(tab, ReaderPanel.actions(ui), function(id, menu)
        ReaderPanel.executeAction(id, ui, menuCallbacks(menu))
    end)
end

---@class BookQuickPanelNativeTab
---@field icon string
---@field remember boolean
---@field _book_ui table|nil
---@field callback fun()|nil

--- 创建并预填充桌面面板 Tab。
---@return BookQuickPanelNativeTab
local function newDesktopTab()
    local tab = {
        icon = DESKTOP_TAB_ICON,
        remember = false,
        [DESKTOP_MARKER] = true,
    }
    tab.callback = function() populateDesktop(tab) end
    populateDesktop(tab)
    return tab
end

--- 创建并预填充阅读面板 Tab。
---@param ui table|nil
---@return BookQuickPanelNativeTab
local function newReaderTab(ui)
    local tab = {
        icon = READER_TAB_ICON,
        remember = false,
        _book_ui = ui,
        [READER_MARKER] = true,
    }
    tab.callback = function() populateReader(tab) end
    populateReader(tab)
    return tab
end

--- 若不存在则向菜单注入桌面面板 Tab。
---@param menu table|nil
---@return nil
local function injectDesktopTab(menu)
    local tabs = menu and menu.tab_item_table
    if type(tabs) ~= "table" then return end
    for _, tab in ipairs(tabs) do
        if tab[DESKTOP_MARKER] then return end
    end
    table.insert(tabs, 1, newDesktopTab())
end

--- 若不存在则注入阅读面板 Tab，并同步当前 ReaderUI。
---@param menu table|nil
---@return nil
local function injectReaderTab(menu)
    local tabs = menu and menu.tab_item_table
    if type(tabs) ~= "table" then return end
    for _, tab in ipairs(tabs) do
        if tab[READER_MARKER] then
            tab._book_ui = menu.ui
            return
        end
    end
    table.insert(tabs, 1, newReaderTab(menu.ui))
end

--- 一次性 patch 文件管理器菜单，注入桌面面板 Tab。
---@return nil
local function installFileManagerMenu()
    local ok, Menu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or type(Menu) ~= "table" or Menu._book_desktop_panel_patched then return end
    if type(Menu.setUpdateItemTable) ~= "function" then return end
    Menu._book_desktop_panel_patched = true
    local original = Menu.setUpdateItemTable
    Menu.setUpdateItemTable = function(self, ...)
        original(self, ...)
        injectDesktopTab(self)
    end
end

--- 查找指定标记 Tab 的索引。
---@param menu table
---@param marker string
---@return number|nil
local function tabIndex(menu, marker)
    if not menu.tab_item_table and menu.setUpdateItemTable then
        menu:setUpdateItemTable()
    end
    for i, tab in ipairs(menu.tab_item_table or {}) do
        if tab[marker] then return i end
    end
end

--- 阅读模式下把 filemanager Tab 重定向到 Book 桌面。
---@param ReaderMenu table
---@return nil
local function patchFileBrowserButton(ReaderMenu)
    if ReaderMenu._book_filebrowser_patched then return end
    ReaderMenu._book_filebrowser_patched = true
    local original = ReaderMenu.getDefaultMenuButtons
    if type(original) ~= "function" then return end
    ReaderMenu.getDefaultMenuButtons = function(self)
        local buttons = original(self)
        local fm = buttons and buttons.filemanager
        if fm and type(fm.callback) == "function" then
            fm.callback = function()
                self:onTapCloseMenu()
                local ui = self.ui
                if ui and ui.onClose then ui:onClose() end
                openBookDesktop()
            end
        end
        return buttons
    end
end

--- 一次性 patch 阅读菜单，注入桌面/阅读面板 Tab 与原生设置项。
---@return nil
local function installReaderMenu()
    local ok, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if not ok or type(ReaderMenu) ~= "table" or ReaderMenu._book_reader_panel_patched
        or type(ReaderMenu.setUpdateItemTable) ~= "function" then return end
    ReaderMenu._book_reader_panel_patched = true
    -- 顶部 Book 快捷面板与底部原生配置菜单解耦：打开顶部面板时不联动底部菜单；
    -- 底部区域仍由 KOReader 独立的 config tap zone 打开。
    if G_reader_settings and type(G_reader_settings.readSetting) == "function"
        and G_reader_settings:readSetting("show_bottom_menu") == nil then
        G_reader_settings:saveSetting("show_bottom_menu", false)
    end
    patchFileBrowserButton(ReaderMenu)
    local original = ReaderMenu.setUpdateItemTable
    ReaderMenu.setUpdateItemTable = function(self, ...)
        original(self, ...)
        NativeSettings.inject(self)
        injectDesktopTab(self)
        injectReaderTab(self)
    end
    if not ReaderMenu._book_reader_panel_show_patched and type(ReaderMenu.onShowMenu) == "function" then
        ReaderMenu._book_reader_panel_show_patched = true
        local original_show = ReaderMenu.onShowMenu
        ReaderMenu.onShowMenu = function(self, tab_index, ...)
            -- 无论从手势还是上次记忆的 Tab 打开，都直接落到阅读面板 Tab。
            injectDesktopTab(self)
            injectReaderTab(self)
            return original_show(self, tabIndex(self, READER_MARKER) or tab_index, ...)
        end
    end
end

--- 返回当前活跃的 ReaderUI 或 FileManager 菜单。
---@return table|nil
local function activeMenu()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok and ReaderUI.instance or nil
    if reader and not reader.tearing_down and reader.menu then return reader.menu end

    local FileManager
    ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local file_manager = ok and FileManager.instance or nil
    if file_manager and not file_manager.tearing_down and file_manager.menu then
        return file_manager.menu
    end
end

--- 判断菜单是否属于阅读会话。
---@param menu table|nil
---@return boolean
local function isReaderMenu(menu)
    return menu ~= nil and menu.ui ~= nil and menu.ui.document ~= nil
end

--- 切换到指定 Tab，返回是否成功。
---@param menu table
---@param tab_index number|nil
---@return boolean
local function switchToTab(menu, tab_index)
    if not tab_index then return false end
    local opened = menu.menu_container and menu.menu_container[1]
    if opened and opened.switchMenuTab then
        opened:switchMenuTab(tab_index)
        return true
    end
    if menu.onShowMenu then
        menu:onShowMenu(tab_index)
        return true
    end
    return false
end

---@param mode "desktop"|"reader"|nil
---@return boolean
function Native.show(mode)
    local menu = activeMenu()
    if not menu then return false end

    if mode == "reader" then
        -- 桌面（FileManager）菜单不注入阅读面板，阅读面板只在阅读菜单里出现。
        if not isReaderMenu(menu) then return false end
        if not menu.tab_item_table and menu.setUpdateItemTable then menu:setUpdateItemTable() end
        injectDesktopTab(menu)
        injectReaderTab(menu)
        return switchToTab(menu, tabIndex(menu, READER_MARKER))
    end

    if mode == "desktop" or mode == nil then
        if not menu.tab_item_table and menu.setUpdateItemTable then menu:setUpdateItemTable() end
        injectDesktopTab(menu)
        local reader_idx = tabIndex(menu, READER_MARKER)
        local desktop_idx = tabIndex(menu, DESKTOP_MARKER)
        if mode == nil and reader_idx then
            return switchToTab(menu, reader_idx)
        end
        return switchToTab(menu, desktop_idx)
    end

    return false
end

---@param host_ui table|nil
---@param opts table|nil { reader: boolean|nil }
function Native.install(host_ui, opts)
    opts = opts or {}
    patchTouchMenu()
    if opts.reader then
        local ok, err = pcall(installReaderMenu)
        if not ok then logger.err("book reader native menu install failed:", err) end
        if host_ui and host_ui.menu then
            NativeSettings.inject(host_ui.menu)
            injectDesktopTab(host_ui.menu)
            injectReaderTab(host_ui.menu)
        end
        return
    end
    local ok, err = pcall(installFileManagerMenu)
    if not ok then logger.err("book native quick panel install failed for file manager:", err) end
    if host_ui and host_ui.menu and not host_ui.document then
        injectDesktopTab(host_ui.menu)
    end
end

---@type BookQuickPanelNative
return Native
