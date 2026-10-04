--[[--
lockscreen 阅读统计：卡片高度必须服从面板预算。

@module tests.features.lockscreen.components.stats_spec
--]]

local Assert = require("support.assert")

local function subtitleOf(blocks)
    for _, block in ipairs(blocks) do
        if type(block.text) == "string" and block.text:find("章节", 1, true) then
            return block.text
        end
    end
end

local book = {
    source_id = "moon",
    stable_id = "book",
    percent = 50,
    page = 100,
    total_pages = 200,
    total_seconds = 3600,
    buckets = {
        { label = "09-01", seconds = 600 },
        { label = "09-02", seconds = 1200 },
    },
}
local chart_opts

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255 }
end

package.preload["features.lockscreen.components.current"] = function()
    return { book = function() return book end }
end

package.preload["features.lockscreen.components.util"] = function()
    return {
        MUTED = 3,
        DIM = 4,
        RULE = 5,
        progress = function(value)
            return value.percent, string.format("%d / %d 页", value.page, value.total_pages)
        end,
        chapterLine = function(value) return value.chapter_title or "阅读中" end,
        duration = function(seconds) return tostring(seconds) end,
        emptyBlocks = function() return {} end,
        coverBlock = function(_, x, y, w, h)
            return { kind = "panel", x = x, y = y, width = w, height = h }
        end,
        progressBlocks = function(x, y, width)
            return { { kind = "rule", x = x, y = y, width = width, height = 8 } }, 8
        end,
    }
end

package.preload["features.lockscreen.components.chart"] = function()
    return {
        appendBars = function(_, opts) chart_opts = opts end,
    }
end

package.loaded["features.lockscreen.components.stats"] = nil
local Stats = require("features.lockscreen.components.stats")
local rect = {
    x = 30, y = 40, w = 420, h = 528,
    pad = 18, text_x = 48, text_w = 384, radius = 10,
}
local blocks = Stats.blocks(rect)

Assert.eq(blocks[1].kind, "panel")
Assert.is_true(blocks[1].y >= rect.y)
Assert.is_true(blocks[1].y + blocks[1].height <= rect.y + rect.h)
Assert.is_true(chart_opts.height >= 0)
Assert.is_true(chart_opts.y + chart_opts.height + 18 <= blocks[1].y + blocks[1].height)
Assert.is_nil(subtitleOf(blocks))

book.chapter_title = "第一章"
Assert.eq(subtitleOf(Stats.blocks(rect)), "章节 · 第一章")
