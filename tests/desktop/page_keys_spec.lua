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
package.preload["ui/geometry"] = ctorModule
package.preload["desktop.gesture"] = function() return { range = function() return {} end } end
package.preload["gettext"] = function() return function(text) return text end end
local desktop_settings = {}
package.preload["utils.settings"] = function()
    return { get = function(name) assert(name == "desktop"); return desktop_settings end }
end
local keys, few = true, false
package.preload["device"] = function()
    return {
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
        hasKeys = function() return keys end,
        hasFewKeys = function() return few end,
    }
end
local InputContainer = {}
function InputContainer:extend(value) return setmetatable(value, { __index = self }) end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end

package.loaded["desktop"] = nil
local Desktop = require("desktop")
Desktop.build = function() end

local function make()
    local d = setmetatable({ key_events = {} }, { __index = Desktop })
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

-- 少键设备：不占用方向键。
few = true
Assert.eq(table.concat(make().key_events.DesktopPageNext[1][1], ","), "RPgFwd,LPgFwd")

-- 纯触屏：不注册。
keys = false
Assert.is_nil(make().key_events.DesktopPageNext)

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

return true
