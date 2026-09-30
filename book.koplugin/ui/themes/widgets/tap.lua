--[[--
点击区：给任意控件套一层 tap 手势，尺寸取控件本身。callback 为 nil 时原样返回控件（不吞事件）。

  Tap.wrap(widget, function(ges) … end)   -- ges.pos 是点按坐标；点击区自身位置在返回值的 dimen

@module koplugin.book.ui.themes.widgets.tap
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")

---@class BookThemeTap
local Tap = {}

---@param widget table
---@param callback fun(ges: table)|nil
---@return table
function Tap.wrap(widget, callback)
    if not callback then return widget end
    local size = widget:getSize()
    local tap = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }, widget }
    tap.ges_events = {
        TapThemeArea = {
            GestureRange:new{ ges = "tap", range = function() return tap.dimen end },
        },
    }
    function tap:onTapThemeArea(_arg, ges)
        callback(ges)
        return true
    end
    return tap
end

return Tap
