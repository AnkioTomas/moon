--[[-- features.panel.widget.slider：硬件档、拖动节流、圆头滑轨。 --]]

local Assert = require("support.assert")

local function widget()
    local W = {}
    function W:extend(proto)
        local C = {}
        setmetatable(C, { __index = proto })
        function C:new(o)
            o = o or {}
            setmetatable(o, { __index = C })
            if o.init then o:init() end
            return o
        end
        return C
    end
    W.new = function(_, opts)
        local o = opts or {}
        o.x, o.y = o.x or 0, o.y or 0
        setmetatable(o, { __index = W })
        return o
    end
    return W
end

local Input = widget()
function Input:paintTo(_bb, x, y)
    self.dimen.x, self.dimen.y = x, y
end
function Input:free() end

local dirty = {}
local queued = {}
local now = 0
local screen = { low_pan_rate = true }

package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_, target, refresh, region)
            dirty[#dirty + 1] = { target = target, refresh = refresh, region = region }
        end,
        scheduleIn = function(_, _delay, fn)
            queued[#queued + 1] = fn
        end,
        unschedule = function(_, fn)
            for i = #queued, 1, -1 do
                if queued[i] == fn then table.remove(queued, i) end
            end
        end,
    }
end
package.preload["ui/time"] = function()
    return {
        now = function() return now end,
        s = function(seconds) return seconds end,
    }
end
package.preload["device"] = function()
    return { screen = screen }
end
package.preload["ui/geometry"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/container/inputcontainer"] = function() return Input end
package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui/widget/horizontalgroup"] = widget
package.preload["ui/widget/horizontalspan"] = widget
package.preload["ui.themes"] = function()
    return {
        px = function(n) return n end,
        color = function(n) return n end,
        current = function()
            return {
                space = { sm = 8 },
                control = { icon = 22 },
                color = { ink = 0, page = 255 },
                progress = { track = 221, fill = 0 },
            }
        end,
    }
end
package.preload["ui.themes.widgets.icon"] = function()
    return { widget = function(opts) return opts end }
end

local parent = {}
local changes = {}
local SliderRow = require("features.panel.widget.slider")

local function row(kind, value, floor, on_level)
    return SliderRow:new{
        width = 300,
        height = 42,
        kind = kind,
        min = 0,
        max = 24,
        floor = floor,
        value = value,
        show_parent = parent,
        on_level = on_level,
    }
end

local slider = row("brightness", 6, 1, function(kind, fraction)
    changes[#changes + 1] = { kind = kind, fraction = fraction }
    return true
end)

Assert.not_nil(slider.ges_events.Tap)
Assert.not_nil(slider.ges_events.Pan)
Assert.not_nil(slider.ges_events.PanRelease)
Assert.not_nil(slider.ges_events.HoldPan)
Assert.eq(slider[1][1][1].name, "brightness_low")
Assert.eq(slider[1][1].dimen.h, 42)
Assert.eq(slider[1][5][1].name, "brightness_high")

-- 轨道中点是第 12 档，fraction 给 setLevel 的逆运算，正好 0.5。
Assert.is_true(slider:onTap(nil, { pos = { x = 150, y = 20 } }))
Assert.eq(changes[1].kind, "brightness")
Assert.eq(changes[1].fraction, 0.5)
Assert.eq(slider.value, 12)
Assert.eq(dirty[1].target, parent)
Assert.eq(dirty[1].refresh, "ui")
Assert.eq(dirty[1].region, slider.dimen)

-- 同一档不写硬件，也不再刷。
Assert.is_true(slider:onTap(nil, { pos = { x = 150, y = 20 } }))
Assert.len(changes, 1)
Assert.len(dirty, 1)

-- 亮度轨道最左是开灯最低档 1，不是关灯的 0。轨道起点 = 图标 22 + 间距 8。
Assert.is_true(slider:onTap(nil, { pos = { x = 30, y = 20 } }))
Assert.eq(changes[2].fraction, 1 / 24)
Assert.eq(slider.value, 1)

-- 左右图标逐档加减，不跳到两头。图标宽 22，右图标从 278 起。
local nudges = {}
local nudged = row("brightness", 6, 1, function(_kind, fraction)
    nudges[#nudges + 1] = fraction
    return true
end)
Assert.is_true(nudged:onTap(nil, { pos = { x = 10, y = 20 } }))
Assert.eq(nudged.value, 5)
Assert.eq(nudges[1], 5 / 24)
Assert.is_true(nudged:onTap(nil, { pos = { x = 290, y = 20 } }))
Assert.eq(nudged.value, 6)
Assert.eq(nudges[2], 6 / 24)
-- 已经在最低开灯档，再点左边不动，也不关灯。
nudged.value = 1
Assert.is_true(nudged:onTap(nil, { pos = { x = 10, y = 20 } }))
Assert.eq(nudged.value, 1)
Assert.len(nudges, 2)
nudged.value = 24
Assert.is_true(nudged:onTap(nil, { pos = { x = 290, y = 20 } }))
Assert.eq(nudged.value, 24)
Assert.len(nudges, 2)

local warmth_changes = {}
local warmth = row("warmth", 6, 0, function(kind, fraction)
    warmth_changes[#warmth_changes + 1] = { kind = kind, fraction = fraction }
    return true
end)
Assert.eq(warmth[1][1][1].name, "ac_unit")
Assert.eq(warmth[1][5][1].name, "wb_incandescent")
Assert.is_true(warmth:onTap(nil, { pos = { x = 30, y = 20 } }))
Assert.eq(warmth_changes[1].kind, "warmth")
Assert.eq(warmth_changes[1].fraction, 0)
Assert.eq(warmth.value, 0)

-- 墨水屏拖动：第一档马上画，接着的档合并，松手补最后一帧。
local drags = {}
local drag = row("brightness", 6, 1, function(kind, fraction)
    drags[#drags + 1] = { kind = kind, fraction = fraction }
    return true
end)
local dirty_before = #dirty
Assert.is_true(drag:onPan(nil, { pos = { x = 150, y = 20 } }))
Assert.eq(#dirty, dirty_before + 1)
Assert.eq(drag.value, 12)
Assert.is_true(drag:onPan(nil, { pos = { x = 210, y = 20 } }))
Assert.eq(drag.value, 18)
Assert.eq(#dirty, dirty_before + 1)
Assert.len(queued, 1)
Assert.is_true(drag:onPan(nil, { pos = { x = 269, y = 20 } }))
Assert.eq(drag.value, 24)
Assert.len(queued, 1)
Assert.eq(#drags, 3)
Assert.is_true(drag:onPanRelease())
Assert.eq(#dirty, dirty_before + 2)
Assert.len(queued, 0)
Assert.eq(drags[3].fraction, 1)

-- 硬件拒绝时滑杆停在原档。
local refused = row("brightness", 6, 1, function() return false end)
Assert.is_true(not refused:onTap(nil, { pos = { x = 150, y = 20 } }))
Assert.eq(refused.value, 6)

-- 圆头：轨道、填充、黑环、白心。拇指按当前档落在轨道内。
local paints = {}
local bb = {
    paintRoundedRect = function(_, x, y, w, h, color, radius)
        paints[#paints + 1] = { kind = "rect", x = x, y = y, w = w, h = h, color = color, radius = radius }
    end,
    paintCircle = function(_, x, y, radius, color)
        paints[#paints + 1] = { kind = "circle", x = x, y = y, radius = radius, color = color }
    end,
}
refused:paintTo(bb, 10, 20)
Assert.eq(refused.dimen.x, 10)
Assert.eq(refused.dimen.y, 20)
Assert.eq(paints[1].kind, "rect")
Assert.eq(paints[1].color, 221)
Assert.eq(paints[1].x, 40)
Assert.eq(paints[1].w, 240)
Assert.eq(paints[2].kind, "rect")
Assert.eq(paints[2].color, 0)
Assert.eq(paints[3].kind, "circle")
Assert.eq(paints[3].color, 0)
Assert.eq(paints[3].x, 104)
Assert.eq(paints[3].y, 41)
Assert.eq(paints[4].kind, "circle")
Assert.eq(paints[4].color, 255)
Assert.eq(paints[4].radius, 6)

-- 非墨水屏没有节流，每一档都立刻画。
screen.low_pan_rate = false
local fast_dirty = #dirty
local fast = row("brightness", 6, 1, function() return true end)
Assert.is_true(fast:onPan(nil, { pos = { x = 150, y = 20 } }))
Assert.is_true(fast:onPan(nil, { pos = { x = 210, y = 20 } }))
Assert.eq(#dirty, fast_dirty + 2)
Assert.len(queued, 0)
