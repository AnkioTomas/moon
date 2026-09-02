--[[-- 阅读页独立原生图标 Tab 的离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function()
    return { isTouchDevice = function() return false end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, setDirty = function() end }
end
package.preload["lockscreen.init"] = function()
    return { refresh = function() end }
end
package.preload["utils.settings"] = function()
    return {
        get = function()
            return { book_xray_show_marks = true }
        end,
        save = function() end,
    }
end

local native_updates = 0
local TouchMenu = {}
function TouchMenu:updateItems() native_updates = native_updates + 1 end
package.preload["ui/widget/touchmenu"] = function() return TouchMenu end

local executed, action_ui, refreshed = {}, nil, 0
package.preload["ui.panel.reader"] = function()
    return {
        actions = function()
            return {
                { id = "toc", title = "目录", icon = "menu_book", enabled = true },
                { id = "sync", title = "同步", icon = "cloud_sync", enabled = true },
            }
        end,
        executeAction = function(id, ui, opts)
            executed[#executed + 1] = id
            action_ui = ui
            opts.refresh()
            return true
        end,
    }
end
package.preload["ui.panel.desktop"] = function()
    return {
        menuActions = function()
            return {{ id = "night", title = "夜间模式", active = true }}
        end,
        executeAction = function() return true end,
    }
end

local ReaderMenu = {}
function ReaderMenu:setUpdateItemTable()
    self.tab_item_table = {
        { id = "navi", icon = "appbar.navigation" },
        { id = "setting", icon = "appbar.settings", { id = "status_bar" } },
    }
end
package.preload["apps/reader/modules/readermenu"] = function() return ReaderMenu end

local ui = {
    dialog = {},
    document = {},
    font = { font_face = "Book Sans", onSetFont = function() end },
}
local Native = require("ui.panel.native")
Native.install(ui, { reader = true })
Native.install(ui, { reader = true })
Assert.is_true(TouchMenu._book_panel_patched)
Assert.is_true(ReaderMenu._book_reader_panel_patched)
TouchMenu:updateItems()
Assert.eq(native_updates, 1)

local menu = setmetatable({ ui = ui }, { __index = ReaderMenu })
menu:setUpdateItemTable()
Assert.len(menu.tab_item_table, 4)
local tab = menu.tab_item_table[1]
Assert.is_true(tab._book_reader_panel)
Assert.eq(tab.icon, "appbar.pageview")
Assert.len(tab, 2)
Assert.is_true(menu.tab_item_table[2]._book_quick_panel)

local setting = menu.tab_item_table[4]
Assert.eq(setting.id, "setting")
Assert.eq(setting[1].id, "book_reader_save_default")
Assert.eq(setting[2].id, "status_bar")

tab.callback()
tab[2].callback({
    updateItems = function() refreshed = refreshed + 1 end,
    closeMenu = function() end,
})
Assert.eq(executed[1], "sync")
Assert.eq(action_ui, ui)
Assert.eq(refreshed, 1)

local first_menu_patch = ReaderMenu.setUpdateItemTable
Native.install(ui, { reader = true })
Assert.eq(ReaderMenu.setUpdateItemTable, first_menu_patch)

local shown_tab
function menu:onShowMenu(index) shown_tab = index end
package.preload["apps/reader/readerui"] = function()
    return { instance = { menu = menu, tearing_down = false } }
end
Assert.is_true(require("ui.panel.native").show("reader"))
Assert.eq(shown_tab, 1)
