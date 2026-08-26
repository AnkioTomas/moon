--[[-- 阅读菜单安装时保留用户已有的 show_bottom_menu 设置。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function() return { isTouchDevice = function() return true end } end
package.preload["ui/uimanager"] = function() return { show = function() end, setDirty = function() end } end
package.preload["ui.panel.native_settings"] = function() return { inject = function() end } end
package.preload["ui.panel.desktop"] = function() return { menuActions = function() return {} end } end
package.preload["ui.panel.reader"] = function() return { actions = function() return {} end } end
package.preload["ui/widget/touchmenu"] = function()
    return { updateItems = function() end, switchMenuTab = function() end }
end
package.preload["apps/filemanager/filemanagermenu"] = function()
    return { setUpdateItemTable = function() end }
end
package.preload["apps/reader/readerui"] = function() return { instance = nil } end
package.preload["apps/filemanager/filemanager"] = function() return { instance = nil } end

local ReaderMenu = { setUpdateItemTable = function() end, getDefaultMenuButtons = function() return {} end }
package.preload["apps/reader/modules/readermenu"] = function() return ReaderMenu end

local previous_settings = _G.G_reader_settings
local saved = {}
_G.G_reader_settings = {
    readSetting = function() return true end,
    saveSetting = function(_, key, value) saved[key] = value end,
}

package.loaded["ui.panel.native"] = nil
local Native = require("ui.panel.native")
Native.install({}, { reader = true })
Assert.is_nil(saved.show_bottom_menu)

_G.G_reader_settings = previous_settings
