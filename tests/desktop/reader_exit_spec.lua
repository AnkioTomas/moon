--[[-- 阅读模式下 filebrowser Tab 重定向到 Book 桌面的离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function() return { isTouchDevice = function() return true end } end

local next_tick
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        nextTick = function(_, callback) next_tick = callback end,
    }
end

local drawer_on = true
local opened_desktop = 0
package.preload["desktop"] = function()
    return {
        open = function() opened_desktop = opened_desktop + 1 end,
        ensureFileManager = function() return { book = {} } end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function() return { drawer_opens_desktop = drawer_on } end }
end
package.preload["menu"] = function()
    return { openOnStart = function() return true end }
end

-- ReaderMenu 桩按正式版 v2026.07 的形状：按钮在 init 里内联固化，没有 getDefaultMenuButtons；
-- setUpdateItemTable 末尾 MenuSorter 把按钮摘进 tab_item_table 后将 menu_items.filemanager 置 nil。
-- fresh_buttons 模拟 nightly：重建先把按钮回填进 menu_items（换新表），其余相同。
local native_calls = 0
local function nativeButton()
    return {
        icon = "appbar.filebrowser",
        remember = false,
        callback = function()
            native_calls = native_calls + 1
            return "native"
        end,
    }
end
local ReaderMenu = {}
ReaderMenu.__index = ReaderMenu
local function newReaderMenu(ui)
    local self = setmetatable({}, ReaderMenu)
    self.ui = ui
    self.menu_items = { filemanager = nativeButton() }
    return self
end
function ReaderMenu:setUpdateItemTable()
    if self.fresh_buttons then self.menu_items.filemanager = nativeButton() end
    local fm = self.menu_items.filemanager
    fm.id = "filemanager"
    self.tab_item_table = { fm }
    self.menu_items.filemanager = nil
end
function ReaderMenu:onTapCloseMenu() self.closed = (self.closed or 0) + 1 end
package.preload["apps/reader/modules/readermenu"] = function() return ReaderMenu end

local function drawerTab(menu) return menu.tab_item_table[1] end

-- 实例在 install 前就已建好（正式版按钮此时已固化），接管仍必须生效。
local reader_closed = 0
local menu = newReaderMenu({ onClose = function() reader_closed = reader_closed + 1 end })
local native_tab = menu.menu_items.filemanager
require("desktop.reader_exit").install()
menu:setUpdateItemTable()
Assert.is_nil(menu.menu_items.filemanager)
local tab = drawerTab(menu)
Assert.is_true(tab == native_tab)
Assert.is_true(tab._book_drawer_patched)
Assert.is_false(tab.remember)

tab.callback()
Assert.eq(menu.closed, 1)
Assert.eq(native_calls, 0, "开关开时不得走原生文件浏览器")
Assert.eq(reader_closed, 0, "菜单关闭后不得在点击调用栈里同步关闭文档")
Assert.eq(opened_desktop, 0)
Assert.not_nil(next_tick)
next_tick()
Assert.eq(reader_closed, 1)
Assert.eq(opened_desktop, 1)

-- 正式版形状下重复重建菜单：正式版不会重建已固化的 Tab，这里只断言同一张 Tab 不叠包。
tab.callback()
Assert.eq(menu.closed, 2)
next_tick()
Assert.eq(reader_closed, 2)
Assert.eq(opened_desktop, 2)

-- nightly 形状：每次重建换新 Tab 表，新表同样被接管且只包一层。
local nightly_closed = 0
local nightly = newReaderMenu({ onClose = function() nightly_closed = nightly_closed + 1 end })
nightly.fresh_buttons = true
nightly:setUpdateItemTable()
nightly:setUpdateItemTable()
drawerTab(nightly).callback()
Assert.eq(native_calls, 0)
next_tick()
Assert.eq(nightly_closed, 1)
Assert.eq(opened_desktop, 3)

-- 开关关：走原生文件浏览器，不回桌面（只测正式版形状）。
drawer_on = false
tab.callback()
Assert.eq(native_calls, 1)
Assert.eq(opened_desktop, 3)
