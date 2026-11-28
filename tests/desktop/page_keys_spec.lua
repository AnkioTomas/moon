--[[-- 桌面物理翻页键：有键设备注册 PgFwd/PgBack（键多再加左右方向键），按语义转成当前页签的左右滑并吃掉按键。 --]]

local Assert = require("support.assert")

local function emptyModule() return {} end
local function ctorModule() return { new = function(_, o) return o or {} end } end
for _, name in ipairs({
    "ui/bidi", "ffi/blitbuffer", "ui/gesturerange", "ui/widget/overlapgroup", "utils.log", "utils.perf",
    "ui.themes", "ui.themes.widgets.box", "ui.themes.widgets.tabbar", "ui/uimanager",
}) do
    package.preload[name] = emptyModule
end
for _, name in ipairs({
    "desktop.pages.home", "desktop.pages.library", "desktop.pages.store",
    "desktop.pages.insight", "desktop.pages.setting", "desktop.topbar",
}) do
    package.preload[name] = ctorModule
end
package.preload["utils.log"] = function() return { info = function() end, dbg = function() end } end
package.preload["ui/geometry"] = ctorModule
package.preload["ui/uimanager"] = function() return { _window_stack = {} } end
package.preload["desktop.gesture"] = function()
    return { range = function() return {} end, dispatcher = function(fm) return { fm = fm } end }
end
package.preload["gettext"] = function() return function(text) return text end end
local desktop_settings = {}
local ui_settings = {}
package.preload["utils.settings"] = function()
    return { get = function(name)
        if name == "ui" then return ui_settings end
        assert(name == "desktop")
        return desktop_settings
    end }
end
local keys, few, dpad, is_touch = true, false, false, false
package.preload["device"] = function()
    return {
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
        hasKeys = function() return keys end,
        hasFewKeys = function() return few end,
        hasDPad = function() return dpad end,
        isTouchDevice = function() return is_touch end,
        input = { group = { Back = { "Back" } } },
    }
end
local InputContainer = {}
function InputContainer:extend(value) return setmetatable(value, { __index = self }) end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end

package.loaded["desktop"] = nil
local Desktop = require("desktop")
Desktop.build = function() end

local function make()
    local d = setmetatable({ key_events = {}, plugin = { ui = {} } }, { __index = Desktop })
    d:init()
    return d
end

-- 键多的设备：侧键 + 方向键。
local d = make()
local next_keys = d.key_events.DesktopPageNext[1][1]
Assert.eq(table.concat(next_keys, ","), "RPgFwd,LPgFwd,Right")
Assert.eq(table.concat(d.key_events.DesktopPagePrev[1][1], ","), "RPgBack,LPgBack,Left")
Assert.eq(d.key_events.DesktopPageNext.event, "DesktopTurn")
Assert.eq(d.key_events.DesktopPageNext.args, 1)
Assert.eq(d.key_events.DesktopPagePrev.args, -1)
Assert.is_true(d.key_events.DesktopBack ~= nil, "登记返回键")
Assert.eq(d.key_events.DesktopBack[1][1][1], "Back")

-- 有实体键：Home 切首页 tab，Menu 开顶部下拉菜单（同顶栏下滑的 quickpanel.show）。
Assert.eq(d.key_events.DesktopHome[1][1], "Home")
Assert.eq(d.key_events.DesktopMenu[1][1], "Menu")
local switched, panel_scope
d.switchTab = function(_, id) switched = id end
require("utils.extension").add("quickpanel.show", function(scope) panel_scope = scope end)
Assert.is_true(d:onDesktopHome())
Assert.eq(switched, "home")
Assert.is_true(d:onDesktopMenu())
Assert.eq(panel_scope, "desktop")
Assert.eq(switched, "home", "Menu 不再切设置 tab")
d.switchTab = nil

-- 少键设备：不占用方向键。
few = true
Assert.eq(table.concat(make().key_events.DesktopPageNext[1][1], ","), "RPgFwd,LPgFwd")

-- fiveway 设备：方向键留给焦点导航，翻页键只翻页签，并登记焦点三键。
few, dpad = false, true
local fv = make()
Assert.eq(table.concat(fv.key_events.DesktopPageNext[1][1], ","), "RPgFwd,LPgFwd", "有 fiveway 时左右键不挪给翻页")
Assert.is_true(fv.key_events.FocusUp ~= nil and fv.key_events.FocusDown ~= nil
    and fv.key_events.FocusLeft ~= nil and fv.key_events.FocusRight ~= nil and fv.key_events.FocusSelect ~= nil,
    "登记方向焦点键")
Assert.is_nil(fv.key_events.FocusHold, "长按只靠中心键按住计时，不另登组合键")
-- 长按：首页直接进编辑，其它页签不进；已在编辑态不重复触发
local edited
local home_page = { editing = false, enterEdit = function(p) edited = "home"; p.editing = true end }
fv.page = function(_, id) return id == "home" and home_page or {} end
fv.tab = "library"
Assert.is_true(fv:onFocusHold())
Assert.is_nil(edited, "非首页不进编辑")
fv.tab = "home"
fv._focus_idx = 3
Assert.is_true(fv:onFocusHold())
Assert.eq(edited, "home")
Assert.is_nil(fv._focus_idx, "进编辑重置焦点")
edited = nil
Assert.is_true(fv:onFocusHold())
Assert.is_nil(edited, "已在编辑态不重复进")

-- 触屏 + 方向键（混合设备）：靠点按操作，不登记焦点键、不画框。
is_touch = true
local hybrid = make()
Assert.is_true(hybrid.key_events.FocusDown == nil and hybrid.key_events.FocusSelect == nil,
    "触屏设备即便有方向键也不登记焦点键")
is_touch = false
dpad = false

-- 纯触屏也登记标准键：外接蓝牙不一定会改变 hasKeys。
keys = false
local touch = make()
Assert.eq(table.concat(touch.key_events.DesktopPageNext[1][1], ","), "RPgFwd,LPgFwd")
Assert.is_true(touch.key_events.DesktopHome == nil, "无实体键不登记 Home")
Assert.is_true(touch.key_events.DesktopMenu == nil, "无实体键不登记 Menu")
keys = true

-- 按键转成当前页签的左右滑，并吃掉按键。
local got = {}
d.tab = "library"
local library = { onEvent = function(_, event, payload) got[#got + 1] = event .. ":" .. payload.direction end }
---@cast library BookLibrary
d.library = library
Assert.is_true(d:onDesktopTurn(1))
Assert.is_true(d:onDesktopTurn(-1))
Assert.eq(table.concat(got, ","), "swipe:west,swipe:east")

-- 当前页签不处理事件也照样吃掉，不漏给文件管理器。
d.tab = "settings"
local settings = {}
---@cast settings BookSettings
d.settings = settings
Assert.is_true(d:onDesktopTurn(1))

-- 「桌面物理翻页键」关闭：不处理、返回 false，按键交给下层；再打开立即恢复，无需重启。
got = {}
d.tab = "library"
desktop_settings.page_keys = false
Assert.is_false(d:onDesktopTurn(1))
Assert.len(got, 0)
desktop_settings.page_keys = true
Assert.is_true(d:onDesktopTurn(1))
Assert.len(got, 1)
ui_settings.pager_keys = false
Assert.is_false(d:onDesktopTurn(1))
Assert.len(got, 1)
Assert.is_true(d:onBookWindowPage(1), "显式映射动作不受原始按键开关影响")
Assert.len(got, 2)
Assert.is_true(d:onBookWindowClose(), "桌面不响应关闭弹窗动作")
local UIManager = require("ui/uimanager")
UIManager._window_stack = { { widget = d } }
InputContainer.handleEvent = function() return false end
Assert.is_true(d:handleEvent({ handler = "onKeyPress", args = {
    { match = function() return true end },
} }), "关闭翻页功能也不把标准翻页键漏给下层")

return true
