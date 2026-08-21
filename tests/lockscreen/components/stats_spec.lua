--[[--
lockscreen.components.stats：阅读统计主体的书籍信息布局。

@module tests.lockscreen.components.stats_spec
--]]

local Assert = require("support.assert")

local book = {
    stable_id = "book-1",
    title = "一本文字很多的测试书",
    authors = "测试作者",
    chapter_title = "第8章 继续前进",
    chapter_idx = 8,
    chapter_count = 20,
    cover = "/covers/book-1.png",
    percent = 42,
    total_seconds = 3600,
    total_pages = 300,
    page = 126,
    buckets = {
        { label = "06-01", seconds = 60 },
        { label = "06-02", seconds = 120 },
    },
}
local chart_opts

package.preload["lockscreen.context"] = function()
    return { currentBook = function() return book end }
end
package.preload["ui.components.chart"] = function()
    return {
        appendBars = function(blocks, opts)
            chart_opts = opts
            blocks[#blocks + 1] = { kind = "chart" }
        end,
    }
end
package.loaded["lockscreen.components.stats"] = nil
package.loaded["lockscreen.context"] = nil
package.loaded["ui.components.chart"] = nil

local Stats = require("lockscreen.components.stats")
local blocks = Stats.blocks{
    x = 20, y = 40, w = 440, h = 680,
    pad = 16, text_x = 36, text_w = 408, radius = 10,
}

local texts = {}
local cover
local rules = {}
local progress_bars = 0
local page_block
for _, block in ipairs(blocks) do
    if block.text then texts[#texts + 1] = block.text end
    if block.kind == "image" then cover = block end
    if block.kind == "rule" then rules[#rules + 1] = block end
    if block.kind == "bar" then progress_bars = progress_bars + 1 end
    if block.text and block.text:find("126 / 300 页", 1, true) then page_block = block end
end

local function hasText(value)
    for _, text in ipairs(texts) do
        if text == value then return true end
    end
    return false
end

local function containsText(value)
    for _, text in ipairs(texts) do
        if text:find(value, 1, true) then return true end
    end
    return false
end

Assert.is_true(hasText(book.title))
Assert.is_true(hasText(book.authors))
Assert.is_true(hasText("章节 · 继续前进"))
Assert.is_true(containsText("126 / 300 页"))
Assert.is_false(hasText("页数暂无"))
Assert.is_false(hasText("剩余 174 页"))
Assert.is_false(hasText("剩余 58%"))
Assert.is_false(hasText("阅读统计"))
Assert.not_nil(cover)
Assert.eq(cover.path, book.cover)
Assert.eq(#rules, 2)
Assert.eq(rules[1].height, 8)
Assert.eq(rules[1].color, require("ffi/blitbuffer").COLOR_GRAY_E)
Assert.eq(rules[2].height, 8)
Assert.eq(rules[2].color, require("ffi/blitbuffer").COLOR_GRAY_E)
Assert.eq(progress_bars, 0)
Assert.eq(chart_opts.bar_cap_ratio, 0.20)
Assert.is_true(chart_opts.height <= math.floor(680 * 0.28))
Assert.not_nil(page_block)
Assert.is_true(rules[2].y >= page_block.y + 30)

local compact = Stats.blocks{
    x = 20, y = 40, w = 440, h = 576,
    pad = 16, text_x = 36, text_w = 408, radius = 10,
}
local compact_panel
for _, block in ipairs(compact) do
    if block.kind == "panel" then compact_panel = block break end
end
Assert.eq(Stats.preferred_height, 0.56)
Assert.eq(compact_panel.height, 576)

book.total_pages = 0
book.page = 0
local no_pages = Stats.blocks{
    x = 20, y = 40, w = 440, h = 576,
    pad = 16, text_x = 36, text_w = 408, radius = 10,
}
local no_page_text = false
for _, block in ipairs(no_pages) do
    if block.text == "页数暂无" then no_page_text = true end
end
Assert.is_true(no_page_text)
