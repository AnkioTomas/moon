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
package.preload["ui/uimanager"] = function() return { show = function() end } end

local native_update_calls = 0
local TouchMenu = {}
function TouchMenu:updateItems()
    native_update_calls = native_update_calls + 1
end
package.preload["ui/widget/touchmenu"] = function() return TouchMenu end

local executed, refreshed = {}, 0
package.preload["ui.desktop.panel"] = function()
    return {
        menuActions = function()
            return {
                { id = "night", title = "夜间模式", active = true },
                { id = "plugin.example.popup", title = "插件页面", active = false },
            }
        end,
        executeAction = function(id, opts)
            executed[#executed + 1] = id
            opts.refresh()
            return true
        end,
    }
end

local FileManagerMenu = {}
function FileManagerMenu:setUpdateItemTable()
    self.tab_item_table = {{ icon = "appbar.menu" }}
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

local NativePanel = require("ui.desktop.panel.native")
NativePanel.install()
NativePanel.install()
Assert.is_true(TouchMenu._book_quick_panel_patched)
TouchMenu:updateItems()
TouchMenu.updateItems({ item_table = { _book_quick_panel = true } })
Assert.eq(native_update_calls, 2)

local existing = { menu = { tab_item_table = {{ icon = "appbar.menu" }} } }
NativePanel.install(existing)
Assert.is_true(existing.menu.tab_item_table[1]._book_quick_panel)

local file_menu = setmetatable({}, { __index = FileManagerMenu })
file_menu:setUpdateItemTable()
Assert.len(file_menu.tab_item_table, 2)
local tab = file_menu.tab_item_table[1]
Assert.is_true(tab._book_quick_panel)
Assert.eq(tab.icon, "appbar.contrast")
Assert.len(tab, 2)

local shown_tab
function file_menu:onShowMenu(index) shown_tab = index end
active_file_manager.menu = file_menu
Assert.is_true(NativePanel.show())
Assert.eq(shown_tab, 1)

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
Assert.is_true(reader_menu.tab_item_table[1]._book_quick_panel)
