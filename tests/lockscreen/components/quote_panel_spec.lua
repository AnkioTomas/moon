--[[--
lockscreen 引用面板：白底 panel + 共享 Quote widget。

@module tests.lockscreen.components.quote_panel_spec
--]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_WHITE = 255,
        COLOR_GRAY_3 = 3,
        COLOR_GRAY_4 = 4,
        COLOR_GRAY_5 = 5,
        COLOR_BLACK = 0,
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

package.preload["utils.text"] = function()
    return {
        truncateUtf8 = function(text, n)
            return tostring(text):sub(1, n)
        end,
    }
end

local last_build
package.preload["ui.views.quote"] = function()
    return {
        contentHeight = function(opts)
            local lines = opts and opts.lines or 2
            local body = opts and opts.body_size or 15
            return 40 + lines * body
        end,
        new = function(_, opts)
            local quote = opts.data
            last_build = { quote = quote, opts = opts }
            return {
                widget = { id = "quote", text = quote.text, source = quote.source },
                height = opts.height,
                build = function(self) return self.widget end,
            }
        end,
    }
end

package.loaded["lockscreen.components.quote_panel"] = nil
local QuotePanel = require("lockscreen.components.quote_panel")

local blocks = QuotePanel.blocks("短句", "出处", "center-center", false)
Assert.len(blocks, 2)
Assert.eq(blocks[1].kind, "panel")
Assert.eq(blocks[2].kind, "widget")
Assert.eq(blocks[2].x, 50)
Assert.eq(blocks[2].width, 208)
Assert.eq(last_build.quote.text, "短句")
Assert.eq(last_build.quote.source, "出处")
Assert.eq(last_build.opts.pad_x, 0)

local long = string.rep("很长的句子", 300)
blocks = QuotePanel.blocks(long, "出处", "center-center", true)
Assert.is_true(#last_build.quote.text < #long)
Assert.matches(last_build.quote.text, "…$")
Assert.is_true(blocks[1].height <= 800 * 0.88)
Assert.eq(blocks[2].kind, "widget")

return true
