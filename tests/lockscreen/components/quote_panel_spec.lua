--[[--
lockscreen 引用面板：统一边距与长文边界。

@module tests.lockscreen.components.quote_panel_spec
--]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_WHITE = 255,
        COLOR_GRAY_3 = 3,
        COLOR_GRAY_4 = 4,
        COLOR_GRAY_5 = 5,
    }
end

package.preload["lockscreen.layout"] = function()
    return {
        portraitSize = function() return 480, 800 end,
        panel = function(opts)
            local width = opts.wide and 412 or 240
            local pad = 16
            return {
                x = 34, y = 40, w = width, h = opts.height or 500,
                pad = pad, text_x = 34 + pad, text_w = width - pad * 2,
                radius = 10,
            }
        end,
    }
end

package.preload["lockscreen.render"] = function()
    return {
        measureText = function(text, width, size)
            local chars_per_line = math.max(1, math.floor(width / size))
            return math.ceil(#text / chars_per_line) * size
        end,
    }
end

package.loaded["lockscreen.components.quote_panel"] = nil
local QuotePanel = require("lockscreen.components.quote_panel")

local blocks = QuotePanel.blocks("短句", "出处", "center-center", false)
Assert.eq(blocks[2].x, 50)
Assert.eq(blocks[2].width, 208)
Assert.eq(blocks[3].x, 50)
Assert.eq(blocks[3].width, 208)
Assert.is_true(blocks[4].y > blocks[3].y)
Assert.is_true(blocks[5].y > blocks[4].y)

local long = string.rep("很长的句子", 300)
blocks = QuotePanel.blocks(long, "出处", "center-center", true)
Assert.is_true(#blocks[3].text < #long)
Assert.matches(blocks[3].text, "…$")
Assert.is_true(blocks[1].height <= 800 * 0.88)
Assert.is_true(blocks[4].y > blocks[3].y)
Assert.is_true(blocks[5].y > blocks[4].y)
