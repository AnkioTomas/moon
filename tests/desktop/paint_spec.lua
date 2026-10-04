--[[-- 桌面整页重画前先等上一次刷新结束，避免墨水屏控制器读到半帧。 --]]

local Assert = require("support.assert")

local function emptyModule() return {} end
for _, name in ipairs({
    "ui/bidi",
    "ffi/blitbuffer",
    "ui/geometry",
    "ui/gesturerange",
    "ui/widget/overlapgroup",
    "utils.log",
    "utils.perf",
    "desktop.pages.home",
    "desktop.pages.library",
    "desktop.pages.store",
    "desktop.pages.insight",
    "desktop.pages.setting",
    "desktop.topbar",
    "ui.themes",
    "ui.themes.widgets.box",
    "ui.themes.widgets.tabbar",
    "utils.settings",
}) do
    package.preload[name] = emptyModule
end
package.preload["ui/uimanager"] = emptyModule
package.preload["gettext"] = function()
    return function(text) return text end
end

local order = {}
package.preload["device"] = function()
    return { screen = { refreshWaitForLast = function() order[#order + 1] = "wait" end } }
end
local InputContainer = {}
function InputContainer:extend(value)
    return setmetatable(value, { __index = self })
end
function InputContainer:paintTo(bb, x, y)
    order[#order + 1] = { bb = bb, x = x, y = y }
end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end

package.loaded["desktop"] = nil
local Desktop = require("desktop")
local desktop = setmetatable({}, { __index = Desktop })
local bb = {}
desktop:paintTo(bb, 3, 4)

Assert.len(order, 2)
Assert.eq(order[1], "wait", "must wait for the previous refresh before painting")
Assert.eq(order[2].bb, bb)
Assert.eq(order[2].x, 3)
Assert.eq(order[2].y, 4)

return true
