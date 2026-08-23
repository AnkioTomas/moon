--[[-- 原生菜单 filebrowser Tab 不被劫持的离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function()
    return { isTouchDevice = function() return true end }
end
package.preload["ui/uimanager"] = function() return { show = function() end } end

package.preload["ui/widget/touchmenu"] = function()
    return { updateItems = function() end, switchMenuTab = function() end }
end
package.preload["ui.panel.desktop"] = function()
    return {
        menuActions = function() return { { id = "night", title = "夜间模式", active = true } } end,
        sliders = function() return {} end,
        executeAction = function() return true end,
    }
end

local fm_menu = {
    ui = {},
    tab_item_table = nil,
}

function fm_menu:setUpdateItemTable()
    self.tab_item_table = {
        { id = "filemanager_settings", icon = "appbar.filebrowser", sub_item_table = { { text = "Settings" } } },
        { id = "setting", icon = "appbar.settings" },
    }
end
function fm_menu:onShowMenu() end

package.preload["apps/filemanager/filemanagermenu"] = function() return fm_menu end
package.preload["apps/reader/modules/readermenu"] = function()
    return { setUpdateItemTable = function() end }
end
package.preload["apps/filemanager/filemanager"] = function() return { instance = nil } end
package.preload["apps/reader/readerui"] = function() return { instance = nil } end

local Native = require("ui.panel.native")
Native.install()

local function findTab(id)
    for _, tab in ipairs(fm_menu.tab_item_table or {}) do
        if tab.id == id then return tab end
    end
end

fm_menu:setUpdateItemTable()
local filebrowser = findTab("filemanager_settings")
Assert.eq(filebrowser.id, "filemanager_settings")
-- 不劫持 filebrowser Tab，始终保留原生 sub_item_table 与回调。
Assert.is_nil(filebrowser.callback)
Assert.is_true(filebrowser.sub_item_table ~= nil)
Assert.is_nil(filebrowser.remember)
