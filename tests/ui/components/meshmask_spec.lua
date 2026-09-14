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
    return { COLOR_BLACK = 0 }
end

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
