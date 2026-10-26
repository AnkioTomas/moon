--[[-- ui.widgets.plain_cover：彩屏上色板补饱和，灰度屏保持原色板。 --]]

local Assert = require("support.assert")

local color_enabled = false
local vivid_calls = {}
package.preload["device"] = function()
    return { screen = {
        night_mode = false,
        scaleBySize = function(_, n) return n end,
        isColorEnabled = function() return color_enabled end,
    } }
end
package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_BLACK = 0, COLOR_WHITE = 255,
        ColorRGB32 = function(r, g, b) return r * 0x10000 + g * 0x100 + b end,
    }
end
package.preload["ui/font"] = function()
    return { getFace = function() return {} end }
end
package.preload["ui/geometry"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/widget/textwidget"] = function()
    return { new = function(_, opts)
        opts.getSize = function() return { w = 10, h = 10 } end
        return opts
    end }
end
package.preload["ui/widget/widget"] = function()
    return { extend = function(_, t)
        t.new = function(_, opts)
            local o = opts or {}
            setmetatable(o, { __index = t })
            o:init()
            return o
        end
        return t
    end }
end
package.preload["ui.themes"] = function()
    return { vivid = function(value)
        vivid_calls[#vivid_calls + 1] = value
        return 0x112233
    end }
end
package.preload["util"] = function()
    return { splitToChars = function(s)
        local out = {}
        for i = 1, #s do out[#out + 1] = s:sub(i, i) end
        return out
    end }
end

local PlainCover = require("ui.widgets.plain_cover")

local cover = PlainCover:new{ title = "ABC", author = "", width = 100, height = 140 }
Assert.eq(#vivid_calls, 0, "灰度屏不补饱和")
Assert.is_true(cover.bg > 0xFF, "色板按 RGB 打包")

color_enabled = true
cover = PlainCover:new{ title = "ABC", author = "", width = 100, height = 140 }
Assert.eq(#vivid_calls, 1, "彩屏补一次饱和")
Assert.eq(cover.bg, 0x112233, "补饱和后的色板才是封面底色")

return true
