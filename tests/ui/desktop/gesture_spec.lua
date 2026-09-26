--[[-- 桌面把手势先交给文件管理器里已配置的 gestures touch zone。 --]]

local Assert = require("support.assert")

local function emptyModule() return {} end
for _, name in ipairs({
    "ui/bidi",
    "ffi/blitbuffer",
    "ui/widget/container/framecontainer",
    "ui/geometry",
    "ui/gesturerange",
    "ui/widget/overlapgroup",
    "utils.log",
    "utils.perf",
    "ui.desktop.home",
    "ui.desktop.library",
    "ui.desktop.store",
    "ui.desktop.insight",
    "ui.desktop.settings",
    "ui.views.topbar",
    "ui.views.bottombar",
    "ui.components.bookui",
}) do
    package.preload[name] = emptyModule
end
package.preload["ui/uimanager"] = emptyModule
package.preload["device"] = function() return { screen = {} } end
package.preload["gettext"] = function()
    return function(text) return text end
end

local base_calls = 0
local InputContainer = {}
function InputContainer:extend(value)
    return setmetatable(value, { __index = self })
end
function InputContainer:onGesture(ev)
    for _, zone in ipairs(self._ordered_touch_zones) do
        if zone.handler(ev) then return true end
    end
end
function InputContainer:handleEvent()
    base_calls = base_calls + 1
    return "base"
end
package.preload["ui/widget/container/inputcontainer"] = function() return InputContainer end

package.loaded["ui.desktop"] = nil
local Desktop = require("ui.desktop")

local hits = {}
local function zone(id, result)
    return { def = { id = id }, handler = function()
        hits[#hits + 1] = id
        return result
    end }
end

local fm = {
    gestures = { gestures = { tap_left_bottom_corner = { toggle_frontlight = true }, hold_top_right_corner = {} } },
    _ordered_touch_zones = {
        zone("filemanager_tap", true),
        zone("one_finger_swipe_left_edge_up_pan", true),
        zone("hold_top_right_corner", nil),
        zone("tap_left_bottom_corner", true),
    },
}
local BAR_Y = 90
local bar_taps = 0
local desktop = setmetatable({
    plugin = { ui = fm },
    ges_events = { TapBar = { {
        match = function(_, ev) return ev.ges == "tap" and ev.pos.y >= BAR_Y end,
    } } },
    onTapBar = function()
        bar_taps = bar_taps + 1
        return true
    end,
}, { __index = Desktop })
local function gesture(ges, y)
    return { handler = "onGesture", args = { { ges = ges or "tap", pos = { x = 0, y = y or 0 } } } }
end

-- 已配置手势命中：消费事件，不再走桌面控件；FM 自身 zone 与 pan 占位 zone 不转发。
Assert.is_true(desktop:handleEvent(gesture()))
Assert.eq(base_calls, 0)
Assert.eq(#hits, 2)
Assert.eq(hits[1], "hold_top_right_corner")
Assert.eq(hits[2], "tap_left_bottom_corner")

-- 底栏点按归 Tab：左下角默认绑了开关前光，不能吞掉「首页」。
hits = {}
Assert.is_true(desktop:handleEvent(gesture("tap", BAR_Y)))
Assert.eq(bar_taps, 1)
Assert.eq(#hits, 0)
-- 底栏里的非点按手势照常交给文件管理器。
Assert.is_true(desktop:handleEvent(gesture("hold", BAR_Y)))
Assert.eq(bar_taps, 1)
Assert.eq(#hits, 2)

-- 已配置但 handler 不处理（方向不符等）：落回桌面。
hits = {}
fm._ordered_touch_zones = { zone("filemanager_tap", true), zone("hold_top_right_corner", nil) }
Assert.eq(desktop:handleEvent(gesture()), "base")
Assert.eq(base_calls, 1)
Assert.eq(#hits, 1)

-- multiswipe 总入口始终转发，动作由 gestures 插件按方向查。
hits = {}
fm._ordered_touch_zones = { zone("multiswipe", true) }
Assert.is_true(desktop:handleEvent(gesture()))
Assert.eq(hits[1], "multiswipe")

-- 非手势事件、无 gestures 插件、无 plugin：直接走桌面。
hits = {}
Assert.eq(desktop:handleEvent({ handler = "onResume", args = {} }), "base")
fm.gestures = nil
Assert.eq(desktop:handleEvent(gesture()), "base")
Assert.eq(setmetatable({ ges_events = desktop.ges_events }, { __index = Desktop }):handleEvent(gesture()), "base")
Assert.eq(#hits, 0)
Assert.eq(base_calls, 4)
