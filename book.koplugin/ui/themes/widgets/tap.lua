--[[--
点击区：给任意控件套一层 tap / hold 手势，尺寸取控件本身。
点按与长按都为 nil 时原样返回控件（不吞事件）。

  Tap.wrap(widget, function(ges) … end)
  Tap.wrap(widget, tap_fn, hold_fn)   -- ges.pos 是点按 / 长按坐标；点击区自身位置在返回值的 dimen

@module koplugin.book.ui.themes.widgets.tap
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")

---@class BookThemeTap
local Tap = {}

---@param widget table
---@param callback fun(ges: table)|nil
---@param hold_callback fun(ges: table)|nil
---@return table
function Tap.wrap(widget, callback, hold_callback)
    if not callback and not hold_callback then return widget end
    local size = widget:getSize()
    local tap = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }, widget }
    tap.ges_events = {}
    -- handleEvent 先下发给子控件：外层点击区发出的事件会经过嵌套的点击区，只认自己发出的。
    if callback then
        tap.ges_events.TapThemeArea = {
            GestureRange:new{ ges = "tap", range = function() return tap.dimen end },
            args = tap,
        }
        function tap:onTapThemeArea(owner, ges)
            if owner ~= nil and owner ~= self then return end
            callback(ges)
            return true
        end
    end
    if hold_callback then
        tap.ges_events.HoldThemeArea = {
            GestureRange:new{ ges = "hold", range = function() return tap.dimen end },
            args = tap,
        }
        function tap:onHoldThemeArea(owner, ges)
            if owner ~= nil and owner ~= self then return end
            hold_callback(ges)
            return true
        end
    end
    return tap
end

return Tap
