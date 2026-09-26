--[[-- meshmask：单像素交错网点。 --]]

local Assert = require("support.assert")
local painted = {}
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/widget"] = function()
    return {
        extend = function(_, proto)
            local class = proto or {}
            class.new = function(self, opts)
                local o = opts or {}
                setmetatable(o, { __index = self })
                return o
            end
            return class
        end,
    }
end
package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end
local screen = { night_mode = false }
package.loaded["device"] = { screen = screen }
local display = { mesh_mask = true }
package.loaded["utils.settings"] = { get = function() return display end }

package.loaded["ui.components.meshmask"] = nil
local MeshMask = require("ui.components.meshmask")
local mask = MeshMask.widget{ width = 4, height = 2 }
Assert.eq(mask.dimen.w, 4)
Assert.eq(mask.dimen.h, 2)
local bb = {
    setPixel = function(_, x, y, color)
        painted[#painted + 1] = { x = x, y = y, color = color }
    end,
}
mask:paintTo(bb, 0, 0)
-- row0: (0,0)(2,0)；row1: (1,1)(3,1)
Assert.eq(#painted, 4)
Assert.eq(painted[1].x, 0)
Assert.eq(painted[1].y, 0)
Assert.eq(painted[3].x, 1)
Assert.eq(painted[3].y, 1)
Assert.eq(painted[1].color, 0, "日间画黑点")

-- 夜间模式整屏反色：画白点才显示为压暗
painted = {}
screen.night_mode = true
mask:paintTo(bb, 0, 0)
Assert.eq(#painted, 4)
Assert.eq(painted[1].color, 255, "夜间画白点")

-- 设置关闭遮罩：一个点都不画
painted = {}
display.mesh_mask = false
mask:paintTo(bb, 0, 0)
Assert.eq(#painted, 0, "关闭后不画")
