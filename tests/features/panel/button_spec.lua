--[[-- features.panel.widget.button 离线 smoke 用例。 --]]

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
        setmetatable(o, { __index = W })
        if o.init then o:init() end
        return o
    end
    return W
end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_BLACK = 0,
        COLOR_WHITE = 255,
        Color8 = function(c) return c end,
    }
end
package.preload["ui/geometry"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/container/inputcontainer"] = widget
package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui.themes.widgets.icon"] = function()
    return {
        label = function(opts) return opts end,
    }
end
package.preload["ui.themes"] = function()
    return {
        px = function(n) return n end,
        current = function()
            return {
                button = {
                    primary = { bg = 0, ink = 255 },
                    normal = { bg = 238, ink = 0, border_color = 0 },
                },
                control = { border = 1, icon = 22 },
                space = { sm = 8 },
                font = { caption = 11 },
            }
        end,
    }
end
package.preload["ui.themes.widgets.box"] = function()
    return { new = function(_, opts) return opts end }
end

local ActionButton = require("features.panel.widget.button")
local active = ActionButton:new{
    width = 80,
    height = 64,
    id = "night",
    title = "夜间",
    icon = "dark_mode",
    active = true,
    enabled = true,
    on_action = function() end,
}
Assert.not_nil(active[1])
-- Icon.label 的 size 是必填：漏传会在 Theme.fontSize 里崩。
Assert.eq(active[1][1].size, 22)
Assert.is_false(active[1][1].dim)
Assert.is_true(active.onTap(active))

local held = false
local with_hold = ActionButton:new{
    width = 80,
    height = 64,
    id = "wifi",
    title = "Wi-Fi",
    icon = "wifi",
    on_action = function() end,
    on_hold = function()
        held = true
        return true
    end,
}
Assert.is_true(with_hold:onHold())
Assert.is_true(held)

local disabled = ActionButton:new{
    width = 80,
    height = 64,
    id = "wifi",
    title = "Wi-Fi",
    icon = "signal_wifi_4_bar",
    active = false,
    enabled = false,
    on_action = function() end,
}
Assert.is_true(disabled.onTap(disabled))
Assert.is_true(disabled[1][1].dim, "禁用态图标与文案变灰")
