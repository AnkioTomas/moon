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
        COLOR_BLACK = 0, COLOR_WHITE = 255, TYPE_BBRGB32 = 5,
        ColorRGB32 = function(r, g, b) return r * 0x10000 + g * 0x100 + b end,
        new = function(w, h)
            local bb = { w = w, h = h, free = function() end, paintRectRGB32 = function() end }
            bb.getWidth, bb.getHeight = function() return bb.w end, function() return bb.h end
            bb.rotatedCopy = function(_, degree)
                local out = { w = bb.h, h = bb.w, degree = degree, free = function() end }
                out.getPixel = function() return { getColorRGB32 = function() return { r = 0, g = 0, b = 0 } end } end
                out.getWidth, out.getHeight = function() return out.w end, function() return out.h end
                return out
            end
            return bb
        end,
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
        opts.getSize = function()
            local chars = select(2, opts.text:gsub("[^\128-\191]", ""))
            return { w = math.min(10 * chars, opts.max_width or math.huge), h = 10 }
        end
        opts.free = function() end
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
        for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
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

local function painted(opts)
    local seen = {}
    local c = PlainCover:new(opts)
    c.bg = { r = 0, g = 0, b = 0 }
    for _idx, col in ipairs(c.columns) do
        for _jdx, item in ipairs(col) do
            item.w.paintTo = function(_, target, px, py)
                if not target.rotatedCopy then seen[#seen + 1] = { item.w.text, px, py } end
            end
        end
    end
    local blits = {}
    local bb = {
        paintRectRGB32 = function() end, paintBorder = function() end,
        blitFrom = function(_, rot, px, py) blits[#blits + 1] = { rot = rot, x = px, y = py } end,
    }
    c:paintTo(bb, 0, 0)
    return seen, c, blits
end
local seen = painted{ title = "三国演义测", author = "", width = 100, height = 140 }
Assert.eq(#seen, 4, "截断为四字且都画出")
seen = painted{ title = "三国演义测", author = "", width = 100, height = 140, truncate = false }
Assert.eq(#seen, 5, "不截断时转列画全")
Assert.is_true(seen[5][2] < seen[1][2], "转到左边一列")

-- 成对符号逐个顺时针转 90°，汉字仍直立。
local upright, _cover, blits = painted{ title = "《三国》", author = "", width = 100, height = 140 }
Assert.eq(#upright, 2, "汉字直立画")
Assert.eq(#blits, 2, "两个书名号各转一次")
Assert.eq(blits[1].rot.degree, 270, "rotatedCopy 逆时针计角，顺时针 90° 传 270")

-- 英文整词转 90°，宽度折成格数；超长词截断到一列。
local _seen, c, word_blits = painted{ title = "Dune Messiah", author = "", width = 100, height = 140, truncate = false }
Assert.eq(#word_blits, 2, "每个单词一个转向位图")
Assert.eq(#c.columns, 2, "一列放不下两个词时转到左边一列")
c = PlainCover:new{ title = "Supercalifragilisticexpialidocious", author = "", width = 100, height = 140 }
Assert.eq(c.columns[1][1].cells, 4, "超长单词截断到一列")

return true
