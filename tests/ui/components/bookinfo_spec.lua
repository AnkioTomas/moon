--[[-- ui.components.bookinfo：阅读状态绑带与长按入口。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local function widgetModule()
    return {
        new = function(_, opts)
            opts.getSize = opts.getSize or function(self)
                return self.dimen or { w = 10, h = 10 }
            end
            opts.paintTo = opts.paintTo or function() end
            opts.free = opts.free or function() end
            opts.handleEvent = opts.handleEvent or function() return false end
            return opts
        end,
    }
end
for _, name in ipairs({
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/container/inputcontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/overlapgroup",
    "ui/widget/textboxwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
    "ui/widget/textwidget",
    "ui/widget/widget",
}) do
    package.preload[name] = widgetModule
    package.loaded[name] = nil
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/gesturerange"] = widgetModule
package.preload["ui.components.image"] = function() return { widget = function(opts) return opts end } end
package.preload["ui.components.bookui"] = function()
    return { face = function() return {} end, sz = function(v) return v end }
end
package.preload["ui.components.surface"] = function()
    return { card = function(child) return child end, pill = function(child) return child end }
end
package.preload["utils.paths"] = function() return {} end
package.preload["libs/libkoreader-lfs"] = function() return {} end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1 }
end
package.preload["gettext"] = function() return function(s) return s end end

package.loaded["ui.components.bookinfo"] = nil
local BookInfo = require("ui.components.bookinfo")

Assert.eq(BookInfo.statusChar({ is_new = true, read_state = 1 }), "新")
Assert.eq(BookInfo.statusChar({ is_new = false, read_state = 1 }), "读")
Assert.eq(BookInfo.statusChar({ is_new = false, read_state = 0 }), "未")
Assert.eq(BookInfo.statusChar({ is_new = false, read_state = 2 }), "未")

local rects = {}
local fold = BookInfo.statusCornerFold({ read_state = 1 })
fold:paintTo({
    paintRect = function(_, x, y, w, h)
        rects[#rects + 1] = { x = x, y = y, w = w, h = h }
    end,
}, 0, 0)
Assert.eq(#rects, 28)
Assert.eq(rects[1].w, 1)
Assert.eq(rects[#rects].w, 28)
Assert.is_false(fold:handleEvent({}))

local tapped, held = 0, 0
local widget = BookInfo.tappable(100, 150, function()
    tapped = tapped + 1
end, function()
    held = held + 1
end)
Assert.not_nil(widget.ges_events.TapBookInfo)
Assert.not_nil(widget.ges_events.HoldBookInfo)
Assert.is_true(widget:onTapBookInfo())
Assert.is_true(widget:onHoldBookInfo())
Assert.eq(tapped, 1)
Assert.eq(held, 1)

package.loaded["ui.components.bookinfo"] = nil
