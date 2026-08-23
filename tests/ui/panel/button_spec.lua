--[[-- ui.panel.widget.button 离线 smoke 用例。 --]]

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
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
package.preload["ui/geometry"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/container/inputcontainer"] = widget
package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        surface = function() return 200 end,
        actionSurface = function() return 0 end,
        pillRadius = function(h) return math.floor(h / 2) end,
        cardRadius = function() return 8 end,
    }
end
package.preload["ui.components.icon"] = function()
    return {
        label = function(opts) return opts end,
    }
end
package.preload["ui.components.surface"] = function()
    return {
        pill = function(child, opts) return { child = child, opts = opts } end,
    }
end

local ActionButton = require("ui.panel.widget.button")
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
Assert.is_true(active.onTap(active))

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
