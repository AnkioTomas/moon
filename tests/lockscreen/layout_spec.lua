--[[--
layout：九宫格位置与宽窄面板。

@module tests.lockscreen.layout_spec
--]]

local Assert = require("support.assert")

package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
    }
end

package.loaded["lockscreen.layout"] = nil
local Layout = require("lockscreen.layout")

Assert.is_true(Layout.validPosition("center-center"))
Assert.is_false(Layout.validPosition("middle"))

local wide = Layout.panel({ position = "top-left", wide = true, height = 200 })
Assert.eq(wide.x, math.floor(600 * 0.07))
Assert.eq(wide.y, math.floor(600 * 0.07))
Assert.eq(wide.w, 600 - math.floor(600 * 0.07) * 2)

local narrow = Layout.panel({ position = "bottom-right", wide = false, height = 200 })
Assert.is_true(narrow.w < wide.w)
Assert.is_true(narrow.x > wide.x)
Assert.is_true(narrow.y > wide.y)
