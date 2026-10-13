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
        bookHead = function(_, subtitle, x, y, width)
            return { { text = subtitle, x = x, y = y, width = width } }, y + 20
        end,
        progressBlocks = function(x, y, width)
            return { { kind = "rule", x = x, y = y, width = width, height = 6 } }, 6
        end,
        percentText = function(value) return value .. "%" end,
        fitLine = function(text, x, y, width)
            return { text = text, x = x, y = y, width = width }, 20
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

-- 卡片按内容定高、在面板里居中；柱图限高，不把剩余空间全给柱子。
Assert.is_true(blocks[1].height < rect.h, "卡片不应撑满整个面板")
local top_gap = blocks[1].y - rect.y
local bottom_gap = rect.y + rect.h - (blocks[1].y + blocks[1].height)
Assert.is_true(top_gap > 0 and math.abs(top_gap - bottom_gap) <= 1, "上下留白相等")
Assert.is_true(chart_opts.height <= math.floor((rect.w - 48) * 0.38))
Assert.is_true(chart_opts.highlight_last, "今天的柱子加深")
Assert.eq(chart_opts.value_label(600), "10分钟")
Assert.eq(chart_opts.value_label(5400), "1.5小时")
local texts = {}
for _, block in ipairs(blocks) do
    if block.text then texts[#texts + 1] = block.text end
end
for _, label in ipairs({ "累计阅读", "最近 7 天", "日均", "3600", "1800", "900", "50%", "100 / 200 页" }) do
    Assert.contains(texts, label)
end

book.chapter_title = "第一章"
Assert.eq(subtitleOf(Stats.blocks(rect)), "章节 · 第一章")
