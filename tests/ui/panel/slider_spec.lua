--[[-- ui.panel.widget.slider 点击切换与重绘用例。 --]]

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

local TextWidget = widget()
function TextWidget:setText(text) self.text = text end

local dirty = {}
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_, target, refresh, region)
            dirty[#dirty + 1] = { target = target, refresh = refresh, region = region }
        end,
    }
end
package.preload["ui/geometry"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/container/inputcontainer"] = widget
package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui/widget/horizontalgroup"] = widget
package.preload["ui/widget/horizontalspan"] = widget
package.preload["ui/widget/textwidget"] = function() return TextWidget end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function() return {} end,
        progressBar = function(_, _, value)
            return {
                value = value,
                setPercent = function(self, next_value) self.value = next_value end,
            }
        end,
    }
end

local parent = {}
local changes = {}
local SliderRow = require("ui.panel.widget.slider")
local slider = SliderRow:new{
    width = 300,
    height = 42,
    kind = "brightness",
    title = "亮度",
    value = 25,
    show_parent = parent,
    on_level = function(kind, fraction)
        changes[#changes + 1] = { kind = kind, fraction = fraction }
        return true
    end,
}

Assert.not_nil(slider.ges_events.Tap)
Assert.is_nil(slider.ges_events.Pan)
Assert.is_nil(slider.ges_events.PanRelease)
Assert.is_true(slider:onTap(nil, { pos = { x = 165, y = 20 } }))
Assert.eq(changes[1].kind, "brightness")
Assert.eq(changes[1].fraction, 0.5)
Assert.eq(slider.value, 50)
Assert.eq(slider.progress.value, 50)
Assert.eq(slider.value_label.text, "50%")
Assert.eq(dirty[1].target, parent)
Assert.eq(dirty[1].refresh, "ui")
Assert.eq(dirty[1].region, slider.dimen)

-- 同一档位不重复写硬件或刷新屏幕。
Assert.is_true(slider:onTap(nil, { pos = { x = 165, y = 20 } }))
Assert.len(changes, 1)
Assert.len(dirty, 1)
