--[[--
将 Book 快捷面板融入 KOReader 原生顶部菜单。

桌面与阅读页各注入独立 Tab；TouchMenu 内容渲染统一在此 patch，
保留原生遮罩、Tab 栏分割线与页脚。

@module koplugin.book.features.panel.native
--]]

require("l10n").apply()

local Device = require("device")
local UIManager = require("ui/uimanager")

local MoonSettings = require("utils.settings")
local Guard = require("ui.guard")
local Menu = require("features.panel.menu")
local NativeSettings = require("features.panel.native_settings")

---@class BookQuickPanelNative
---@field show fun(mode: "desktop"|"reader"): boolean
---@field install fun(host_ui: table|nil, opts: table|nil)

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
---@field Box table
---@field Theme table
---@field VerticalSpan table
---@field Body BookQuickPanelBody
---@field Header BookQuickPanelHeader
---@field Desktop BookQuickPanelDesktop
---@field ReaderPanel BookQuickPanelReader

--- 延迟加载并缓存面板自绘所需的 UI 模块。
---@return BookQuickPanelWidgets
local function ensureWidgets()
    if Widgets then return Widgets end
    Widgets = {
        Box = require("ui.themes.widgets.box"),
        Theme = require("ui.themes"),
        VerticalSpan = require("ui/widget/verticalspan"),
        Body = require("features.panel.widget.body"),
        Header = require("features.panel.widget.header"),
        Desktop = require("features.panel.desktop"),
        ReaderPanel = require("features.panel.reader"),
    }
    return Widgets
end

--- 顶部菜单抽屉（文件浏览器）图标是否改开月读桌面：启动项为月读且设置未关闭。
---@return boolean
local function drawerOpensDesktop()
    return require("menu").openOnStart() and require("utils.settings").get("desktop").drawer_opens_desktop == true
end

--- 下一 tick 关闭文档并回到月读桌面，而不是 KOReader 原生文件管理器。
---@param ui table|nil
local function closeToDesktop(ui)
    UIManager:nextTick(function()
        if ui and ui.onClose then ui:onClose() end
        local FileManager = require("apps/filemanager/filemanager")
        -- 打开书时 ReaderUI 会关掉 FileManager；这里先重建，否则关闭文档后窗口栈为空直接退出。
        if not FileManager.instance then
            FileManager:showFiles()
        end
        require("desktop").open(FileManager.instance.book)
    end)
end
Native.closeToDesktop = closeToDesktop

--- 用页面底色的主题 Box 包裹面板主体（主体宽度已扣除两侧 pad，居中即内边距）。
---@param body table
---@param W BookQuickPanelWidgets
---@param width number
---@param pad number
---@return table
local function wrapPanel(body, W, width, pad)
    return W.Box:new{
        style = { bg = W.Theme.current().color.page },
        width = width,
        height = pad * 2 + body:getSize().h,
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
    local width, pad = menu.item_width, W.Theme.px(W.Theme.current().space.sm)
    local content_w = width - pad * 2
    local callbacks = menuCallbacks(menu)
    local panel = mode == "reader" and W.ReaderPanel or W.Desktop
    local body_opts = {
        width = content_w,
        show_parent = menu.show_parent,
        editing = tab._book_panel_editing == true,
        on_action = function(id)
            if mode == "reader" then
                W.ReaderPanel.executeAction(id, tab._book_ui, callbacks)
            else
                W.Desktop.executeAction(id, callbacks)
            end
        end,
        on_enter_edit = function()
            tab._book_panel_editing = true
            Menu.refresh(menu)
        end,
        on_exit_edit = function()
            tab._book_panel_editing = false
            Menu.refresh(menu)
        end,
        on_move = function(id, delta)
            panel.move(id, delta)
            Menu.refresh(menu)
        end,
        on_disable = function(id)
            panel.setEnabled(id, false)
            Menu.refresh(menu)
        end,
        on_add = function(id)
            panel.setEnabled(id, true)
            Menu.refresh(menu)
        end,
        addable = function()
            local out = {}
            for _idx, option in ipairs(panel.options()) do
                if option.available and not option.enabled then
                    out[#out + 1] = option
                end
            end
            return out
        end,
    }
    if mode == "reader" then
        local ui = tab._book_ui
        body_opts.header = W.Header:new{
            width = content_w,
            height = W.Theme.px(52),
            on_exit = function()
                Menu.close(menu)
                closeToDesktop(ui)
            end,
        }
        body_opts.actions = W.ReaderPanel.actions(ui)
    else
        body_opts.actions = W.Desktop.menuActions()
        if not body_opts.editing then
            body_opts.sliders = W.Desktop.sliders()
            body_opts.on_level = function(kind, fraction)
                return W.Desktop.setLevel(kind, fraction)
            end
        end
    end
    return wrapPanel(W.Body:new(body_opts), W, width, pad)
end

--- 临时 noop switchMenuTab 后触发 tab.callback，让 Tab 栏分割线按当前内容重算。
---@param menu table
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

--- 替换 TouchMenu 的 item 列表为月读面板自绘内容。
---@param menu table
local function renderPanelContent(menu)
    local W = ensureWidgets()
    syncBarSeparator(menu)
    menu.page, menu.page_num = 1, 1
    menu.item_group:clear()
    menu.layout = {}
    table.insert(menu.item_group, menu.bar)
    table.insert(menu.layout, menu.bar.icon_widgets)
    -- 面板自绘内容从 Tab 栏下移一点，避免贴顶。
    table.insert(menu.item_group, W.VerticalSpan:new{ width = W.Theme.px(W.Theme.current().space.lg) })
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

--- 菜单下沿到屏底的高度；菜单占满屏时 <= 0。
---@param menu table
---@return number top
---@return number height
local function meshSpan(menu)
    local top = menu.dimen.y + menu.dimen.h
    return top, menu.screen_size.h - top
end

--- 绘制菜单下方的主题网点遮罩。
---@param menu table
---@param bb table
---@param x number
local function paintMesh(menu, bb, x)
    local top, h = meshSpan(menu)
    if h <= 0 then return end
    local Mask = require("ui.themes.widgets.mask")
    local Geom = require("ui/geometry")
    Mask:new{ dimen = Geom:new{ w = menu.screen_size.w, h = h } }:paintTo(bb, x, top)
end

--- 一次性 patch TouchMenu：触屏设备命中面板 Tab 时改走自绘渲染；
--- 菜单下方铺主题网点遮罩，点遮罩由原生 TapCloseAllMenus 关菜单。
local function patchTouchMenu()
    local TouchMenu = require("ui/widget/touchmenu")
    if TouchMenu._book_panel_patched then return end
    TouchMenu._book_panel_patched = true
    local original = TouchMenu.updateItems
    TouchMenu.updateItems = function(self, ...)
        local fresh, old_h = self.is_fresh, self.dimen.h
        if panelMode(self.item_table) and Device:isTouchDevice() then
            Guard.call("quick panel render", renderPanelContent, self)
        else
            original(self, ...)
        end
        -- 网点按菜单下沿起算，叠画在下层旧像素上。菜单变高时原生只重画菜单自身，
        -- 下沿一移，新旧网点相位错开叠成更黑的一片：下层必须重画，顺带全刷清残影。
        if (fresh or self.dimen.h ~= old_h) and MoonSettings.get("ui").mesh_mask
            and select(2, meshSpan(self)) > 0 then
            UIManager:setDirty("all", "full")
        end
    end
    local original_paint = TouchMenu.paintTo
    TouchMenu.paintTo = function(self, bb, x, y)
        original_paint(self, bb, x, y)
        Guard.paint("quick panel mesh", paintMesh, self, bb, x)
    end
    -- 编辑态挂在跨次打开复用的 tab 表上；点遮罩 / 返回键关菜单不经面板回调，只能在这里清。
    local original_close = TouchMenu.onCloseWidget
    TouchMenu.onCloseWidget = function(self, ...)
        for _idx, tab in ipairs(self.tab_item_table) do tab._book_panel_editing = nil end
        return original_close(self, ...)
    end
end

--- 把动作列表写入原生 Tab 的 item 数组。
---@param tab table
---@param actions table[]
---@param on_execute fun(id: string, menu: table)
local function populateTab(tab, actions, on_execute)
    -- 触屏设备走 renderPanelContent 自绘，不必填充原生 menu item。
    if Device:isTouchDevice() then return end
    for i = #tab, 1, -1 do table.remove(tab, i) end
    for _idx, action in ipairs(actions) do
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
local function populateDesktop(tab)
    local Panel = require("features.panel.desktop")
    populateTab(tab, Panel.menuActions(), function(id, menu)
        Panel.executeAction(id, menuCallbacks(menu))
    end)
end

--- 用阅读动作填充原生 Tab。
---@param tab table
local function populateReader(tab)
    local ReaderPanel = require("features.panel.reader")
    local ui = tab._book_ui
    populateTab(tab, ReaderPanel.actions(ui), function(id, menu)
        ReaderPanel.executeAction(id, ui, menuCallbacks(menu))
    end)
end

---@class BookQuickPanelNativeTab
---@field icon string Tab 栏图标资源名
---@field remember boolean 是否记忆上次打开的 Tab
---@field _book_ui table|nil 阅读面板绑定的 ReaderUI
---@field _book_panel_editing boolean|nil 现场编辑态；关菜单时清掉
---@field callback fun()|nil 非触屏设备填充原生 menu item

--- 创建并预填充面板 Tab。
---@param marker string DESKTOP_MARKER / READER_MARKER
---@param icon string Tab 栏图标资源名
---@param populate fun(tab: table)
---@param ui table|nil 阅读面板绑定的 ReaderUI
---@return BookQuickPanelNativeTab
local function newTab(marker, icon, populate, ui)
    local tab = {
        icon = icon,
        remember = false,
        _book_ui = ui,
        [marker] = true,
    }
    tab.callback = function() populate(tab) end
    populate(tab)
    return tab
end

--- 若不存在则向菜单注入桌面面板 Tab。
---@param menu table|nil
local function injectDesktopTab(menu)
    local tabs = menu and menu.tab_item_table
    if type(tabs) ~= "table" then return end
    for _idx, tab in ipairs(tabs) do
        if tab[DESKTOP_MARKER] then return end
    end
    table.insert(tabs, 1, newTab(DESKTOP_MARKER, DESKTOP_TAB_ICON, populateDesktop))
end

--- 若不存在则注入阅读面板 Tab，并同步当前 ReaderUI。
---@param menu table|nil
local function injectReaderTab(menu)
    if not menu then return end
    local tabs = menu.tab_item_table
    if type(tabs) ~= "table" then return end
    for _idx, tab in ipairs(tabs) do
        if tab[READER_MARKER] then
            tab._book_ui = menu.ui
            return
        end
    end
    table.insert(tabs, 1, newTab(READER_MARKER, READER_TAB_ICON, populateReader, menu.ui))
end

--- 文件管理器抽屉 Tab：设置开启且桌面未显示时回月读桌面；桌面已开时保留原生设置页。
--- remember=false 是必须的：否则下次开菜单会自动落到这个 Tab，立刻又跳桌面。
---@param menu table FileManagerMenu
local function patchDrawerTab(menu)
    for _idx, tab in ipairs(menu.tab_item_table or {}) do
        if tab.id == "filemanager_settings" then
            if tab._book_drawer_patched then return end
            tab._book_drawer_patched = true
            tab.remember = false
            local native = tab.callback
            tab.callback = function()
                local plugin = menu.ui and menu.ui.book
                if plugin and not plugin.desktop and drawerOpensDesktop() then
                    -- switchMenuTab 在回调后还要渲染本 Tab，关菜单推迟到下一 tick。
                    UIManager:nextTick(function()
                        menu:onCloseFileManagerMenu()
                        require("desktop").open(plugin)
                    end)
                    return
                end
                if native then native() end
            end
            return
        end
    end
end

--- 一次性 patch 文件管理器菜单，注入桌面面板 Tab。
local function installFileManagerMenu()
    local FMMenu = require("apps/filemanager/filemanagermenu")
    if FMMenu._book_desktop_panel_patched then return end
    FMMenu._book_desktop_panel_patched = true
    local original = FMMenu.setUpdateItemTable
    FMMenu.setUpdateItemTable = function(self, ...)
        original(self, ...)
        injectDesktopTab(self)
        patchDrawerTab(self)
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

--- 阅读模式下抽屉（filemanager）Tab 按设置重定向到月读桌面，否则走原生文件浏览器。
---@param ReaderMenu table
local function patchFileBrowserButton(ReaderMenu)
    local original = ReaderMenu.getDefaultMenuButtons
    ReaderMenu.getDefaultMenuButtons = function(self)
        local buttons = original(self)
        local fm = buttons and buttons.filemanager
        if fm and type(fm.callback) == "function" then
            local native = fm.callback
            fm.callback = function()
                if not drawerOpensDesktop() then return native() end
                self:onTapCloseMenu()
                closeToDesktop(self.ui)
            end
        end
        return buttons
    end
end

--- 一次性 patch 阅读菜单，注入桌面/阅读面板 Tab 与原生设置项。
local function installReaderMenu()
    local ReaderMenu = require("apps/reader/modules/readermenu")
    if ReaderMenu._book_reader_panel_patched then return end
    ReaderMenu._book_reader_panel_patched = true
    -- 顶部 Book 快捷面板与底部原生配置菜单解耦：打开顶部面板时不联动底部菜单；
    -- 底部区域仍由 KOReader 独立的 config tap zone 打开。
    if G_reader_settings:readSetting("show_bottom_menu") == nil then
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
    local original_show = ReaderMenu.onShowMenu
    ReaderMenu.onShowMenu = function(self, tab_index, ...)
        -- 无论从手势还是上次记忆的 Tab 打开，都直接落到阅读面板 Tab。
        injectDesktopTab(self)
        injectReaderTab(self)
        return original_show(self, tabIndex(self, READER_MARKER) or tab_index, ...)
    end
end

--- 返回当前活跃的 ReaderUI 或 FileManager 菜单。
---@return table|nil
local function activeMenu()
    local reader = require("apps/reader/readerui").instance
    if reader and not reader.tearing_down and reader.menu then return reader.menu end

    local file_manager = require("apps/filemanager/filemanager").instance
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

---@param mode "desktop"|"reader"
---@return boolean
function Native.show(mode)
    local menu = activeMenu()
    if not menu then return false end
    -- 桌面（FileManager）菜单不注入阅读面板，阅读面板只在阅读菜单里出现。
    if mode == "reader" and not isReaderMenu(menu) then return false end
    if not menu.tab_item_table and menu.setUpdateItemTable then menu:setUpdateItemTable() end
    injectDesktopTab(menu)
    if mode == "reader" then
        injectReaderTab(menu)
        return switchToTab(menu, tabIndex(menu, READER_MARKER))
    end
    return switchToTab(menu, tabIndex(menu, DESKTOP_MARKER))
end

---@param host_ui table|nil
---@param opts table|nil { reader: boolean|nil }
function Native.onCreate(host_ui, opts)
    opts = opts or {}
    patchTouchMenu()
    if opts.reader then
        installReaderMenu()
        if host_ui and host_ui.menu then
            NativeSettings.inject(host_ui.menu)
            injectDesktopTab(host_ui.menu)
            injectReaderTab(host_ui.menu)
        end
        return
    end
    installFileManagerMenu()
    if host_ui and host_ui.menu and not host_ui.document then
        injectDesktopTab(host_ui.menu)
        patchDrawerTab(host_ui.menu)
    end
end

---@type BookQuickPanelNative
return Native
