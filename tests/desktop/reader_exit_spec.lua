--[[-- 阅读模式下 filebrowser Tab 重定向到 Book 桌面的离线用例。 --]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

local logged = {}
package.preload["utils.log"] = function()
    return {
        error = function(...) logged[#logged + 1] = { ... } end,
        flush = function() end, warn = function() end, info = function() end, dbg = function() end,
    }
end
package.preload["version"] = function() return { getShortVersion = function() return "2026.07" end } end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["logger"] = function() return { err = function() end } end
package.preload["device"] = function()
    return { model = "Test", isTouchDevice = function() return true end, input = { group = { Back = { "Back" } } } }
end
package.loaded["patch.manager"] = nil
package.preload["patch.manager"] = function()
    error("阅读菜单接管不应加载核心文件补丁管理器")
end

local next_tick
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        nextTick = function(_, callback) next_tick = callback end,
    }
end

local drawer_on = true
local back_on, settings_error = false, nil
local opened_desktop = 0
package.preload["desktop"] = function()
    return {
        open = function() opened_desktop = opened_desktop + 1 end,
        ensureFileManager = function() return { book = {} } end,
    }
end
package.preload["utils.settings"] = function()
    return { get = function()
        if settings_error then error(settings_error) end
        return { drawer_opens_desktop = drawer_on, back_to_desktop = back_on }
    end }
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
local installed, install_err = pcall(require("desktop.reader_exit").install, "/plugin")
Assert.is_true(installed, install_err)
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
Assert.eq(tab.callback(), "native", "关闭接管时保留原生返回值")
Assert.eq(native_calls, 1)
Assert.eq(opened_desktop, 3)

local reader_on_top, link_selected = true, false
package.loaded["ui.input"] = { isTop = function() return reader_on_top end }
local key = { match = function() return true end }
local ui = {
    link = { isPageLinkSelected = function() return link_selected end },
    onKeyPress = function(_self, event) return "native press", event end,
    onKeyRepeat = function(_self, event) return "native repeat", event end,
}
local ReaderExit = require("desktop.reader_exit")
ReaderExit.attach(ui)
local result, returned_key = ui:onKeyPress(key)
Assert.eq(result, "native press")
Assert.eq(returned_key, key, "原生多返回值透传")
Assert.eq(ui:onKeyRepeat(key), "native repeat")
back_on = true
Assert.is_true(ui:onKeyPress(key))
local scheduled = next_tick
Assert.is_true(ui:onKeyRepeat(key))
Assert.eq(next_tick, scheduled, "按键重复不再次安排关书")
link_selected = true
Assert.eq(ui:onKeyPress(key), "native press", "链接选择仍交给原生处理")
reader_on_top = false
Assert.is_false(ui:onKeyPress(key), "阅读器被弹窗盖住时不响应返回键")

settings_error = "injected reader setting failure"
drawer_on = true
for _idx, handler in ipairs({ "onKeyPress", "onKeyRepeat" }) do
    Assert.is_nil(ui[handler](ui, key), "注入回调错误不得外抛")
    Assert.eq(logged[#logged][2], "reader exit " .. handler)
    local box = Themed.last("text_viewer")
    Assert.matches(box.text, settings_error)
    box:close()
end
local closed_before = menu.closed
Assert.is_nil(tab.callback(), "抽屉同步回调的错误也被隔离")
Assert.eq(logged[#logged][2], "reader exit drawer")
Assert.matches(Themed.last("text_viewer").text, settings_error)
Assert.eq(menu.closed, closed_before)
Assert.eq(next_tick, scheduled, "出错不安排关书")
Themed.last("text_viewer"):close()
