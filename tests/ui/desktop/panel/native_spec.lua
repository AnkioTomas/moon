--[[-- 原生 KOReader 快捷面板 Tab 的离线用例。
@module tests.ui.desktop.panel.native_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function()
    return {
        hasFrontlight = function() return false end,
        hasNaturalLight = function() return false end,
        isTouchDevice = function() return false end,
    }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, setDirty = function() end, nextTick = function(_, fn) fn() end }
end

local drawer_enabled = true
package.preload["host"] = function()
    return { drawerOpensDesktop = function() return drawer_enabled end }
end

local native_update_calls = 0
local TouchMenu = {}
function TouchMenu:updateItems()
    native_update_calls = native_update_calls + 1
end
package.preload["ui/widget/touchmenu"] = function() return TouchMenu end

local executed, refreshed = {}, 0
package.preload["ui.panel.desktop"] = function()
    return {
        menuActions = function()
            return {
                { id = "night", title = "夜间模式", active = true },
                { id = "plugin.example.popup", title = "插件页面", active = false },
            }
        end,
        sliders = function() return {} end,
        executeAction = function(id, opts)
            executed[#executed + 1] = id
            opts.refresh()
            return true
        end,
    }
end

local native_drawer_calls = 0
local FileManagerMenu = {}
function FileManagerMenu:setUpdateItemTable()
    self.tab_item_table = {
        { icon = "appbar.menu" },
        {
            id = "filemanager_settings", icon = "appbar.filebrowser",
            callback = function() native_drawer_calls = native_drawer_calls + 1 end,
        },
    }
end
local ReaderMenu = {}
function ReaderMenu:setUpdateItemTable()
    self.tab_item_table = {{ icon = "appbar.menu" }}
end
local active_file_manager = {}
package.preload["apps/filemanager/filemanagermenu"] = function() return FileManagerMenu end
package.preload["apps/reader/modules/readermenu"] = function() return ReaderMenu end
package.preload["apps/filemanager/filemanager"] = function() return { instance = active_file_manager } end
package.preload["apps/reader/readerui"] = function() return { instance = nil } end

local NativePanel = require("ui.panel.native")
NativePanel.onCreate()
NativePanel.onCreate()
Assert.is_true(TouchMenu._book_panel_patched)
TouchMenu:updateItems()
TouchMenu.updateItems({ item_table = { _book_quick_panel = true } })
Assert.eq(native_update_calls, 2)

local existing = { menu = { tab_item_table = {{ icon = "appbar.menu" }} } }
NativePanel.onCreate(existing)
Assert.is_true(existing.menu.tab_item_table[1]._book_quick_panel)

local file_menu = setmetatable({}, { __index = FileManagerMenu })
file_menu:setUpdateItemTable()
Assert.len(file_menu.tab_item_table, 3)
local tab = file_menu.tab_item_table[1]
Assert.is_true(tab._book_quick_panel)
Assert.eq(tab.icon, "appbar.pokeball")
Assert.len(tab, 2)

local shown_tab
function file_menu:onShowMenu(index) shown_tab = index end
active_file_manager.menu = file_menu
Assert.is_true(NativePanel.show("desktop"))
Assert.eq(shown_tab, 1)
-- 桌面（FileManager）菜单不注入阅读面板。
Assert.is_false(NativePanel.show("reader"))

tab.callback()
Assert.len(tab, 2)
tab[2].callback({
    updateItems = function() refreshed = refreshed + 1 end,
    closeMenu = function() end,
})
Assert.eq(executed[1], "plugin.example.popup")
Assert.eq(refreshed, 1)

local reader_menu = setmetatable({}, { __index = ReaderMenu })
reader_menu:setUpdateItemTable()
Assert.is_nil(reader_menu.tab_item_table[1]._book_quick_panel)

-- 文件管理器抽屉 Tab：开关开且桌面未显示 → 关菜单开桌面；不记忆该 Tab。
local desktop_opens, fm_menu_closes = 0, 0
local fm_plugin = { openDesktop = function() desktop_opens = desktop_opens + 1 end }
local drawer_menu = setmetatable({
    ui = { book = fm_plugin },
    onCloseFileManagerMenu = function() fm_menu_closes = fm_menu_closes + 1 end,
}, { __index = FileManagerMenu })
drawer_menu:setUpdateItemTable()
local drawer = drawer_menu.tab_item_table[3]
Assert.eq(drawer.id, "filemanager_settings")
Assert.eq(drawer.remember, false)
drawer.callback()
Assert.eq(desktop_opens, 1)
Assert.eq(fm_menu_closes, 1)
Assert.eq(native_drawer_calls, 0)

-- 桌面已开：保留原生设置页。
fm_plugin.desktop = {}
drawer.callback()
Assert.eq(desktop_opens, 1)
Assert.eq(native_drawer_calls, 1)

-- 开关关：保留原生设置页。
fm_plugin.desktop = nil
drawer_enabled = false
drawer.callback()
Assert.eq(desktop_opens, 1)
Assert.eq(native_drawer_calls, 2)

-- 重复注入不叠包装。
NativePanel.onCreate({ menu = drawer_menu })
drawer.callback()
Assert.eq(native_drawer_calls, 3)

-- 阅读菜单抽屉按钮：开关关走原生文件浏览器，开则回月读桌面。
local native_reader_fm = 0
function ReaderMenu:getDefaultMenuButtons()
    return { filemanager = { callback = function() native_reader_fm = native_reader_fm + 1 end } }
end
NativePanel.onCreate(nil, { reader = true })
local reader_buttons = setmetatable({ ui = {} }, { __index = ReaderMenu }):getDefaultMenuButtons()
reader_buttons.filemanager.callback()
Assert.eq(native_reader_fm, 1)

local closed_reader_menu = 0
drawer_enabled = true
local tapped = setmetatable({
    ui = {},
    onTapCloseMenu = function() closed_reader_menu = closed_reader_menu + 1 end,
}, { __index = ReaderMenu })
tapped:getDefaultMenuButtons().filemanager.callback()
Assert.eq(closed_reader_menu, 1)
Assert.eq(native_reader_fm, 1)
