--[[--
lockscreen 引用面板：白底 panel + 引号 / 正文 / 署名文字块。

@module tests.features.lockscreen.components.quote_panel_spec
--]]

local Assert = require("support.assert")

package.preload["ffi/blitbuffer"] = function()
    return {
        COLOR_WHITE = 255,
        COLOR_GRAY_3 = 3,
        COLOR_BLACK = 0,
    }
end

package.preload["features.lockscreen.layout"] = function()
    return {
        portraitSize = function() return 480, 800 end,
        panel = function(opts)
            local width = opts.wide and 412 or 240
            local pad = 16
            local h = opts.height or 500
            return {
                x = 34, y = 40, w = width, h = h,
                pad = pad, text_x = 34 + pad, text_w = width - pad * 2,
                radius = 10,
            }
        end,
    }
end

package.preload["features.lockscreen.render"] = function()
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

package.loaded["features.lockscreen.components.quote_panel"] = nil
local QuotePanel = require("features.lockscreen.components.quote_panel")

local blocks = QuotePanel.blocks("短句", "出处", "center-center", false)
Assert.len(blocks, 4)
Assert.eq(blocks[1].kind, "panel")
Assert.eq(blocks[2].text, "“")
Assert.eq(blocks[3].text, "短句")
Assert.eq(blocks[4].text, "—— 出处")
Assert.eq(blocks[4].align, "right")
Assert.eq(blocks[2].x, 50, "引号贴内容左边")
Assert.is_true(blocks[3].x > blocks[2].x + blocks[2].width - 1, "正文让出引号列")
Assert.eq(blocks[3].x + blocks[3].width, 50 + 208, "正文右边与内容区对齐")
Assert.is_true(blocks[4].y > blocks[3].y, "署名在正文下方")
local panel = blocks[1]
local content_top, content_bottom = blocks[3].y, blocks[4].y + 16
Assert.is_true(math.abs((content_top - panel.y) - (panel.y + panel.height - content_bottom)) <= 1,
    "内容在面板里垂直居中")

-- 已带前缀的出处不重复加；空出处不画署名。
blocks = QuotePanel.blocks("短句", "—— 已有", "center-center", false)
Assert.eq(blocks[4].text, "—— 已有")
blocks = QuotePanel.blocks("短句", "", "center-center", false)
Assert.len(blocks, 3)

local long = string.rep("很长的句子", 300)
blocks = QuotePanel.blocks(long, "出处", "center-center", true)
Assert.is_true(#blocks[3].text < #long)
Assert.matches(blocks[3].text, "…$")
Assert.is_true(blocks[1].height <= 800 * 0.88)

return true
