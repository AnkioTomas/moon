--[[--
lockscreen 阅读账单：所有统计查询绑定当前源。

@module tests.lockscreen.components.bill_spec
--]]

local Assert = require("support.assert")

local sources = {}
local function record(source_id)
    sources[#sources + 1] = source_id
end

package.preload["db.stats"] = function()
    return {
        periodDays = function(source_id)
            record(source_id)
            return {}
        end,
        periodHours = function(source_id)
            record(source_id)
            return {}
        end,
        periodSummary = function(source_id)
            record(source_id)
            return {}
        end,
        periodBooks = function(source_id)
            record(source_id)
            return {}
        end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0, COLOR_WHITE = 255 }
end

package.preload["lockscreen.components.library"] = function()
    return { activeSourceId = function() return "moon" end }
end

package.preload["lockscreen.components.util"] = function()
    return {
        dayStart = function() return 100000 end,
        MUTED = 1,
        DIM = 2,
        RULE = 3,
    }
end

package.preload["utils.settings"] = function()
    return {
        get = function()
            return {
                active_source = "wrong-source",
                lock_screen_bill_period = "7d",
            }
        end,
    }
end

package.loaded["lockscreen.components.bill"] = nil
local Bill = require("lockscreen.components.bill")
Bill.data()

Assert.eq(#sources, 2)
for _, source_id in ipairs(sources) do
    Assert.eq(source_id, "moon")
end

sources = {}
local blocks = Bill.blocks({
    x = 0, y = 0, w = 500, h = 800,
    text_x = 20, text_w = 460, pad = 20, radius = 10,
})
Assert.eq(#sources, 2)

local barcode, cutouts = 0, 0
local texts = {}
local logo_block
local brand_block
local brand_subtitle
for _, block in ipairs(blocks) do
    if block.kind == "vbar" then barcode = barcode + 1 end
    if block.kind == "cutout_circle" then cutouts = cutouts + 1 end
    if block.kind == "image" then logo_block = block end
    if block.text == "MOON READING" then brand_block = block end
    if block.text == "阅读账单" then brand_subtitle = block end
    if block.text then texts[#texts + 1] = block.text end
end
Assert.contains(texts, "MOON READING")
Assert.contains(texts, "TOTAL")
Assert.is_true(barcode > 20)
Assert.is_true(cutouts > 4)
Assert.matches(logo_block.file, "book%.koplugin/logo%.png$")
Assert.is_true(logo_block.height >= 64)
Assert.eq(brand_block.y, logo_block.y + 2)
Assert.eq(brand_subtitle.y, brand_block.y + 42)
