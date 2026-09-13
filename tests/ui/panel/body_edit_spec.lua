--[[-- ui.panel.widget.body 现场编辑离线用例。 --]]

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
package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
package.preload["ui/geometry"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/horizontalgroup"] = widget
package.preload["ui/widget/horizontalspan"] = widget
package.preload["ui/widget/container/inputcontainer"] = widget
package.preload["ui/widget/verticalgroup"] = function()
    local W = widget()
    local original_new = W.new
    W.new = function(_, opts)
        local o = original_new(_, opts)
        o.getSize = function() return { w = 200, h = 100 } end
        return o
    end
    return W
end
package.preload["ui/widget/verticalspan"] = widget
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        surface = function() return 200 end,
        actionSurface = function() return 0 end,
        face = function(name, size) return { name = name, size = size } end,
    }
end
package.preload["ui.components.icon"] = function()
    return {
        label = function(opts) return opts end,
        widget = function(opts) return opts end,
    }
end
package.preload["ui.components.surface"] = function()
    return { build = function(opts) return opts end }
end
package.preload["ui.panel.widget.button"] = function()
    local Button = {}
    Button.__index = Button
    function Button:new(opts)
        return setmetatable(opts, self)
    end
    return Button
end
package.preload["ui.panel.widget.slider"] = function()
    return { new = function(_, opts) return opts end }
end

local wraps, dones, adds = 0, 0, 0
package.preload["ui.panel.edit_overlay"] = function()
    return {
        wrap = function(button, meta)
            wraps = wraps + 1
            return { wrapped = true, id = meta.id, index = meta.index, button = button }
        end,
        doneRow = function(_, on_tap)
            dones = dones + 1
            return { kind = "done", on_tap = on_tap }
        end,
        addRow = function(_, on_tap)
            adds = adds + 1
            return { kind = "add", on_tap = on_tap }
        end,
        showAddDialog = function() end,
    }
end

local Body = require("ui.panel.widget.body")

local entered = false
local body = Body:new{
    width = 300,
    actions = {
        { id = "night", title = "夜间", icon = "dark_mode", enabled = true },
        { id = "wifi", title = "Wi-Fi", icon = "wifi", enabled = true },
    },
    sliders = { { kind = "brightness", title = "亮度", value = 40 } },
    on_action = function() end,
    on_enter_edit = function() entered = true end,
    addable = function() return { { id = "rotate", title = "旋转" } } end,
}
Assert.eq(wraps, 0)
Assert.eq(dones, 0)
Assert.not_nil(body.ges_events)
Assert.is_true(body:onHoldPanelEdit())
Assert.is_true(entered)

wraps, dones, adds = 0, 0, 0
local editing = Body:new{
    width = 300,
    editing = true,
    actions = {
        { id = "night", title = "夜间", icon = "dark_mode", enabled = true },
        { id = "wifi", title = "Wi-Fi", icon = "wifi", enabled = true },
    },
    sliders = { { kind = "brightness", title = "亮度", value = 40 } },
    on_exit_edit = function() end,
    on_move = function() end,
    on_disable = function() end,
    addable = function() return { { id = "rotate", title = "旋转" } } end,
}
Assert.eq(wraps, 2)
Assert.eq(dones, 1)
Assert.eq(adds, 1)
Assert.is_nil(editing.ges_events)

return true
