--[[-- PageStrip：两侧翻页 + 中间 dots / title / 双按钮。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(s) return s end end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end } }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255, COLOR_BLACK = 0, COLOR_LIGHT_GRAY = 200, COLOR_GRAY_9 = 90 }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        face = function() return {} end,
        muted = function() return 90 end,
    }
end
package.preload["ui.components.icon"] = function()
    return { widget = function(opts) return { name = opts.name, dim = opts.dim, color = opts.color } end }
end
local function stub()
    return { new = function(_, opts)
        opts = opts or {}
        opts.getSize = function(self) return self.dimen end
        return opts
    end }
end
for _, name in ipairs({
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/inputcontainer",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/linewidget",
    "ui/widget/textwidget",
    "ui/gesturerange",
}) do
    package.preload[name] = stub
end

package.preload["ui/widget/container/framecontainer"] = function()
    return { new = function(_, opts)
        opts.getSize = function(self) return self[1]:getSize() end
        return opts
    end }
end

local PageStrip = require("ui.components.pagestrip")
Assert.is_true(PageStrip.bandH() > 0)
local page, pages = PageStrip.clamp(9, 4)
Assert.eq(page, 4)
Assert.eq(pages, 4)
page, pages = PageStrip.clamp(nil, 0)
Assert.eq(page, 1)
Assert.eq(pages, 1)

local prev, next_ = 0, 0
local strip = PageStrip.widget({
    width = 300,
    page = 2,
    pages = 4,
    center = "dots",
    on_prev = function() prev = prev + 1 end,
    on_next = function() next_ = next_ + 1 end,
})
Assert.eq(strip.width, 300)
Assert.eq(strip.height, PageStrip.bandH())
local dots = strip[1][2][1]
Assert.eq(#dots, 7, "four dots separated by three gaps")
for i = 1, #dots, 2 do
    -- A background-only leaf must measure without needing a child widget.
    Assert.eq(dots[i]:getSize().w, 8)
    Assert.eq(dots[i]:getSize().h, 8)
    Assert.eq(dots[i].background, i == 3 and 0 or 200)
end
strip[1][1][1]:onTapPageStrip()
strip[1][3][1]:onTapPageStrip()
Assert.eq(prev, 1)
Assert.eq(next_, 1)
Assert.eq(strip[1][1][1][1][1].color, 0)
Assert.eq(strip[1][3][1][1][1].color, 0)

local done = 0
strip = PageStrip.widget({
    width = 300,
    page = 1,
    pages = 1,
    center = "title",
    title = "完成",
    on_center = function() done = done + 1 end,
})
Assert.not_nil(strip)

local left, right = strip[1][1][1], strip[1][3][1]
Assert.is_nil(left.onTapPageStrip)
Assert.is_nil(right.onTapPageStrip)
Assert.eq(left[1][1].color, 90)
Assert.eq(right[1][1].color, 90)
strip[1][2]:onTapPageStripTitle()
Assert.eq(done, 1)
Assert.eq(PageStrip.bandH(), 40)

local add = 0
done = 0
strip = PageStrip.widget({
    width = 300,
    page = 1,
    pages = 1,
    center = "title",
    actions = {
        { text = "添加", on_tap = function() add = add + 1 end },
        { text = "完成", on_tap = function() done = done + 1 end },
    },
})
local mid = strip[1][2][1]
Assert.eq(mid[1][1][1].text, "添加")
Assert.eq(mid[3][1][1].text, "完成")
mid[1]:onTapPageStripTitle()
mid[3]:onTapPageStripTitle()
Assert.eq(add, 1)
Assert.eq(done, 1)

return true
