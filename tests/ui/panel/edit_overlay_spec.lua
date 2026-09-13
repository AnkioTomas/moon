--[[-- ui.panel.edit_overlay 离线用例。 --]]

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

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
package.preload["ui/widget/buttondialog"] = widget
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

local Edit = require("ui.panel.edit_overlay")

local moves, disables = {}, {}
local overlay = Edit.wrap({ id = "night" }, {
    id = "night",
    width = 80,
    height = 64,
    index = 2,
    count = 3,
}, {
    on_move = function(id, delta) moves[#moves + 1] = { id = id, delta = delta } end,
    on_disable = function(id) disables[#disables + 1] = id end,
})
Assert.eq(#overlay, 3)
Assert.eq(icons[1].name, "chevron_left")
Assert.eq(icons[2].name, "chevron_right")
Assert.eq(icons[3].name, "close")

local tools = overlay[3][1]
local left = tools[1]
local right = tools[3]
local close = tools[5]
Assert.is_true(left.onTapPanelEdit() == true)
Assert.eq(moves[1].id, "night")
Assert.eq(moves[1].delta, -1)
Assert.is_true(right.onTapPanelEdit() == true)
Assert.eq(moves[2].delta, 1)
Assert.is_true(close.onTapPanelEdit() == true)
Assert.eq(disables[1], "night")

-- 仅一项时不可停用、不可移动
icons = {}
local lone = Edit.wrap({ id = "wifi" }, {
    id = "wifi", width = 80, height = 64, index = 1, count = 1,
}, {
    on_move = function() end,
    on_disable = function() end,
})
Assert.is_nil(lone[3][1][1].onTapPanelEdit)
Assert.is_nil(lone[3][1][3].onTapPanelEdit)
Assert.is_nil(lone[3][1][5].onTapPanelEdit)

local done_tapped = false
local done = Edit.doneRow(200, function() done_tapped = true end)
Assert.is_true(done.onTapPanelEditDone())
Assert.is_true(done_tapped)

local add_tapped = false
local add = Edit.addRow(200, function() add_tapped = true end)
Assert.is_true(add.onTapPanelEditAdd())
Assert.is_true(add_tapped)

return true
