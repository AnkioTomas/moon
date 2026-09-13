--[[-- 首页编辑叠层：设置按钮仅在组件支持设置时出现。 --]]

local Assert = require("support.assert")

local function widget()
    return {
        new = function(_, opts)
            opts = opts or {}
            opts.getSize = function(self) return self.dimen or { w = 0, h = 0 } end
            return opts
        end,
    }
end

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
package.preload["ui/widget/buttondialog"] = widget
package.preload["ui/widget/spinwidget"] = widget
package.preload["ui/widget/container/centercontainer"] = widget
package.preload["ui/widget/container/framecontainer"] = widget
package.preload["ui/geometry"] = widget
package.preload["ui/gesturerange"] = widget
package.preload["ui/widget/horizontalgroup"] = widget
package.preload["ui/widget/horizontalspan"] = widget
package.preload["ui/widget/container/inputcontainer"] = widget
package.preload["ui/widget/overlapgroup"] = widget
package.preload["ui/widget/textwidget"] = widget
package.preload["ui/widget/widget"] = widget
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function(name, size) return { name = name, size = size } end,
    }
end
local icons = {}
package.preload["ui.components.icon"] = function()
    return {
        widget = function(opts)
            icons[#icons + 1] = opts
            return opts
        end,
    }
end

local Edit = require("ui.desktop.home.edit_overlay")
local settings = {}
local function collectTaps(node, out)
    if type(node) ~= "table" then return end
    if node.onTapHomeEdit then out[#out + 1] = node end
    for i = 1, #node do collectTaps(node[i], out) end
end

local overlay = Edit.wrap({ id = "clock" }, {
    id = "clock",
    width = 200,
    height = 80,
    placement = { height = "default" },
    range = { height = 20, limit = 80 },
}, {
    on_delete = function() end,
    on_move = function() end,
    on_height = function() end,
})
Assert.eq(#icons, 3)
Assert.eq(icons[1].name, "delete")
Assert.eq(icons[2].name, "swap_vert")
Assert.eq(icons[3].name, "height")
local taps = {}
collectTaps(overlay[3], taps)
Assert.eq(#taps, 3)
Assert.is_true(overlay[3].onHomeEditBarTap())
Assert.is_true(overlay[2].onHomeEditShieldTap())

icons = {}
local with_settings = Edit.wrap({ id = "weather" }, {
    id = "weather",
    width = 200,
    height = 80,
    placement = { height = "default" },
    range = { height = 20, limit = 80 },
}, {
    on_delete = function() end,
    on_move = function() end,
    on_height = function() end,
    on_settings = function(id) settings[#settings + 1] = id end,
})
Assert.eq(#icons, 4)
Assert.eq(icons[4].name, "settings")
taps = {}
collectTaps(with_settings[3], taps)
Assert.eq(#taps, 4)
Assert.is_true(taps[4].onTapHomeEdit() == true)
Assert.eq(settings[1], "weather")

return true
