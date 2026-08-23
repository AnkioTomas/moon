--[[-- 原生阅读菜单注入：缺省 Tab 打开时正确解析快捷面板 Tab。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function() return { isTouchDevice = function() return true end } end
package.preload["ui/uimanager"] = function() return { show = function() end, setDirty = function() end } end
package.preload["ui.panel.desktop"] = function() return { menuActions = function() return {} end } end
package.preload["ui.panel.reader"] = function() return { actions = function() return {} end } end

local TouchMenu = {}
function TouchMenu:updateItems() end
function TouchMenu:switchMenuTab(_tab_num) end
package.preload["ui/widget/touchmenu"] = function() return TouchMenu end

local ReaderMenu = {}
function ReaderMenu:setUpdateItemTable()
    self.tab_item_table = self.tab_item_table or {}
end
function ReaderMenu:onShowMenu(tab_index)
    self.shown_tab = tab_index
end
package.preload["apps/reader/modules/readermenu"] = function() return ReaderMenu end
package.preload["apps/reader/modules/readerconfig"] = function() return nil end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = { readSetting = function() return nil end }

local Native = require("ui.panel.native")
Native.install({}, { reader = true })

ReaderMenu:onShowMenu(nil)
Assert.eq(ReaderMenu.shown_tab, 1)

_G.G_reader_settings = previous_settings
