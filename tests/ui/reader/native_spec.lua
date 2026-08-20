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
    return { refreshInBackground = function() end }
end

local native_updates = 0
local TouchMenu = {}
function TouchMenu:updateItems() native_updates = native_updates + 1 end
package.preload["ui/widget/touchmenu"] = function() return TouchMenu end

local executed, action_ui, refreshed = {}, nil, 0
package.preload["ui.reader"] = function()
    return {
        actions = function()
            return {
                { id = "toc", title = "目录", icon = "toc", enabled = true },
                { id = "sync", title = "同步", icon = "sync", enabled = true },
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

local ReaderMenu = {}
function ReaderMenu:setUpdateItemTable()
    self.tab_item_table = {
        { id = "navi", icon = "appbar.navigation" },
        { id = "setting", icon = "appbar.settings", { id = "status_bar" } },
    }
end
package.preload["apps/reader/modules/readermenu"] = function() return ReaderMenu end

local ReaderConfig = {
    init = function(self)
        self.options = require("ui/data/koptoptions")
        self.configurable:loadDefaults(self.options)
    end,
    onShowConfigMenu = function() return true end,
}
package.preload["apps/reader/modules/readerconfig"] = function() return ReaderConfig end
local kopt = { prefix = "kopt", { icon = "appbar.textsize", options = {} } }
local cre = { prefix = "copt", { icon = "appbar.textsize", options = {} } }
package.preload["ui/data/koptoptions"] = function() return kopt end
package.preload["ui/data/creoptions"] = function() return cre end
package.preload["document/credocument"] = function()
    return { engineInit = function()
        return { getFontFaces = function() return { "Book Sans", "Book Serif" } end }
    end }
end

local ui = {
    dialog = {},
    font = { font_face = "Book Sans", onSetFont = function() end },
}
local Native = require("ui.reader.native")
Native.install(ui)
Native.install(ui)
Assert.is_true(TouchMenu._book_reader_panel_patched)
TouchMenu:updateItems()
Assert.eq(native_updates, 1)

local menu = setmetatable({ ui = ui }, { __index = ReaderMenu })
menu:setUpdateItemTable()
Assert.len(menu.tab_item_table, 3)
local tab = menu.tab_item_table[1]
Assert.is_true(tab._book_reader_panel)
Assert.eq(tab.icon, "book")
Assert.len(tab, 2)

local setting = menu.tab_item_table[3]
Assert.eq(setting.id, "setting")
Assert.eq(setting[1].id, "book_reader_top_status")
Assert.eq(setting[2].id, "book_reader_bottom_progress")
Assert.eq(setting[3].id, "book_reader_save_default")

tab.callback()
tab[2].callback({
    updateItems = function() refreshed = refreshed + 1 end,
    closeMenu = function() end,
})
Assert.eq(executed[1], "sync")
Assert.eq(action_ui, ui)
Assert.eq(refreshed, 1)

local font_option = kopt[1].options[1]
Assert.is_true(font_option._book_font_option)
Assert.eq(font_option.event, "BookSetFont")
Assert.is_true(cre[1].options[1]._book_font_option)

local first_menu_patch = ReaderMenu.setUpdateItemTable
Native.install(ui)
Assert.eq(ReaderMenu.setUpdateItemTable, first_menu_patch)
