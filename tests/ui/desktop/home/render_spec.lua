--[[--
用 KOReader 实际布局控件验证翻页条和编辑遮罩测量、绘制；无需字体或 native 绘图库。
@module tests.ui.desktop.home.render_spec
--]]
local Assert = require("support.assert")
local frontend = BOOK_TEST_ROOT .. "/koreader/frontend/"
local probe = io.open(frontend .. "ui/widget/container/framecontainer.lua", "r")
if not probe then Assert.skip("KOReader checkout unavailable") end
probe:close()

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255, COLOR_BLACK = 0, COLOR_LIGHT_GRAY = 200,
        isColor8 = function() return true end }
end
package.preload["ui/bidi"] = function()
    return { mirroredUILayout = function() return false end }
end
package.preload["ui/size"] = function()
    return { border = { window = 1 }, padding = { default = 0 } }
end
package.preload["optmath"] = function() return {} end
package.preload["ui/geometry"] = assert(loadfile(frontend .. "ui/geometry.lua"))
package.preload["util"] = function() return {} end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui.components.bookui"] = function()
    return { sz = function(n) return n end, face = function() return {} end, muted = function() return 90 end }
end
for _, name in ipairs({
    "ui/widget/eventlistener", "ui/widget/widget", "ui/widget/container/widgetcontainer",
    "ui/widget/container/framecontainer", "ui/widget/container/centercontainer",
    "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/linewidget",
    "ui/widget/overlapgroup",
}) do
    package.loaded[name] = nil
    package.preload[name] = assert(loadfile(frontend .. name .. ".lua"))
end
local Widget = require("ui/widget/widget")
package.preload["depgraph"] = function() return {} end
package.preload["device"] = function() return { screen = {} } end
package.preload["ui/time"] = function() return {} end
package.preload["ui/event"] = assert(loadfile(frontend .. "ui/event.lua"))
package.preload["ui/widget/container/inputcontainer"] = assert(loadfile(frontend .. "ui/widget/container/inputcontainer.lua"))
package.preload["ui/gesturerange"] = assert(loadfile(frontend .. "ui/gesturerange.lua"))
package.preload["ui.components.icon"] = function()
    return { widget = function() return Widget:new{ dimen = { w = 22, h = 22 } } end }
end
package.preload["ui/widget/textwidget"] = function()
    return { new = function() return Widget:new{ dimen = { w = 28, h = 14 } } end }
end
local PageStrip = require("ui.components.pagestrip")
local dots = {}
local bb = {
    paintRoundedRect = function() end,
    paintRect = function(_, x, y, w, h, color)
        dots[#dots + 1] = { x = x, y = y, w = w, h = h, color = color }
    end,
}
for _, pages in ipairs({ 1, 4 }) do
    for page = 1, pages do
        dots = {}
        local strip = PageStrip.widget{ width = 300, page = page, pages = pages }
        Assert.eq(strip:getSize().w, 300)
        Assert.eq(strip:getSize().h, 40)
        strip:paintTo(bb, 10, 20)
        Assert.eq(#dots, pages)
        for i, dot in ipairs(dots) do
            Assert.eq(dot.w, 8)
            Assert.eq(dot.h, 8)
            Assert.eq(dot.color, i == page and 0 or 200)
            Assert.is_true(dot.x >= 10 and dot.x + dot.w <= 310)
            Assert.is_true(dot.y >= 20 and dot.y + dot.h <= 60)
        end
        strip:free()
    end
end
local title = PageStrip.widget{ width = 300, center = "title", title = "完成" }
title:paintTo(bb, 0, 0)
Assert.eq(title:getSize().h, 40)
title:free()

-- 编辑遮罩也不能用无子项的 FrameContainer。
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/widget/spinwidget"] = function() return {} end
local Edit = require("ui.desktop.home.edit_overlay")
local underlying = 0
local content = Widget:new{ dimen = { w = 300, h = 100 } }
function content:onGesture() underlying = underlying + 1; return true end
local actions = {}
local range, placement = {}, {}
local overlay = Edit.wrap(content,
    { id = "clock", width = 300, height = 100, range = range, placement = placement }, {
        on_delete = function(id) actions[#actions + 1] = "delete:" .. id end,
        on_move = function(id) actions[#actions + 1] = "move:" .. id end,
        on_height = function(id, r, p)
            Assert.eq(r, range)
            Assert.eq(p, placement)
            actions[#actions + 1] = "height:" .. id
        end,
    })
local border = overlay[2][1]
Assert.eq(border:getSize().w, 300)
Assert.eq(border:getSize().h, 100)
local painted_border = 0
local saw_component
bb.paintBorder = function(_, _, _, w, h)
    painted_border = painted_border + 1
    if w == 300 and h == 100 then saw_component = true end
end
local reader_settings = G_reader_settings
G_reader_settings = { nilOrTrue = function() return true end }
local painted, err = pcall(overlay.paintTo, overlay, bb, 30, 60)
G_reader_settings = reader_settings
Assert.is_true(painted, err)
Assert.eq(painted_border, 2)
Assert.is_true(saw_component)
Assert.is_true(overlay[2]:onHomeEditShieldTap())
Assert.is_true(overlay[2]:onHomeEditShieldHold())
local Event = require("ui/event")
local Geom = require("ui/geometry")
local function gesture(kind, x, y)
    return overlay:handleEvent(Event:new("Gesture", { ges = kind, pos = Geom:new{ x = x, y = y } }))
end
for _, x in ipairs({ 40, 84, 128 }) do
    Assert.is_true(gesture("tap", x, 70))
end
Assert.eq(actions[1], "delete:clock")
Assert.eq(actions[2], "move:clock")
Assert.eq(actions[3], "height:clock")
Assert.is_true(gesture("tap", 200, 140))
Assert.is_true(gesture("hold", 40, 70))
Assert.eq(#actions, 3)
Assert.eq(underlying, 0, "edit gestures must never reach the underlying component")
overlay:free()
