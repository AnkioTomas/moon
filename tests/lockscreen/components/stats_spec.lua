--[[--
lockscreen 阅读统计：卡片高度必须服从面板预算。

@module tests.lockscreen.components.stats_spec
--]]

local Assert = require("support.assert")

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
local hero_opts
local chart_opts

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255 }
end

package.preload["lockscreen.components.current"] = function()
    return { book = function() return book end }
end

package.preload["lockscreen.components.util"] = function()
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
    }
end

package.preload["ui.components.bookinfo"] = function()
    return {
        hero = function(_, _, _, opts)
            hero_opts = opts
            return { getSize = function() return { w = opts.width, h = 120 } end }, 120
        end,
        progressRow = function(width)
            return { getSize = function() return { w = width, h = 20 } end }, 20
        end,
    }
end

package.preload["ui.components.chart"] = function()
    return {
        appendBars = function(_, opts) chart_opts = opts end,
    }
end

package.loaded["lockscreen.components.stats"] = nil
local Stats = require("lockscreen.components.stats")
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
Assert.is_nil(hero_opts.subtitle)

book.chapter_title = "第一章"
Stats.blocks(rect)
Assert.eq(hero_opts.subtitle, "章节 · 第一章")
