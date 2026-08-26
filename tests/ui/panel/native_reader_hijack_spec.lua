--[[-- 阅读模式下 filebrowser Tab 重定向到 Book 桌面的离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function() return { isTouchDevice = function() return true end } end

package.preload["ui/uimanager"] = function()
    return { show = function() end }
end
package.preload["ui.panel.native_settings"] = function() return { inject = function() end } end
package.preload["ui.panel.desktop"] = function() return { menuActions = function() return {} end } end
package.preload["ui.panel.reader"] = function() return { actions = function() return {} end } end
package.preload["ui/widget/touchmenu"] = function()
    return { updateItems = function() end, switchMenuTab = function() end }
end
package.preload["apps/filemanager/filemanagermenu"] = function()
    return { setUpdateItemTable = function() end }
end

local opened_desktop = 0
package.preload["apps/filemanager/filemanager"] = function()
    return {
        instance = {
            book = {
                openDesktop = function() opened_desktop = opened_desktop + 1 end,
            },
        },
    }
end
package.preload["apps/reader/readerui"] = function() return { instance = nil } end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = {
    saveSetting = function() end,
}

local original_filemanager_callback = function() return "native" end
local ReaderMenu = {}
function ReaderMenu:getDefaultMenuButtons()
    return {
        filemanager = {
            icon = "appbar.filebrowser",
            remember = false,
            callback = original_filemanager_callback,
        },
    }
end
function ReaderMenu:setUpdateItemTable() end
function ReaderMenu:onTapCloseMenu() self.closed = true end
package.preload["apps/reader/modules/readermenu"] = function() return ReaderMenu end

local Native = require("ui.panel.native")
Native.install({}, { reader = true })

local menu = setmetatable({ ui = { onClose = function() end } }, { __index = ReaderMenu })
local buttons = menu:getDefaultMenuButtons()
Assert.not_nil(buttons.filemanager)
Assert.is_true(type(buttons.filemanager.callback) == "function")
-- 阅读模式下 filebrowser 回调必须被替换为返回 Book 桌面，而不是原生回调。
Assert.is_false(buttons.filemanager.callback == original_filemanager_callback)
Assert.is_false(buttons.filemanager.remember)

buttons.filemanager.callback()
Assert.is_true(menu.closed)
Assert.eq(opened_desktop, 1)

_G.G_reader_settings = previous_settings
