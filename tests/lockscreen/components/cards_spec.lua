--[[--
lockscreen 卡片堆：剩余时间公式、今日时长、贴底排布与半透明卡。

@module tests.lockscreen.components.cards_spec
--]]

local Assert = require("support.assert")

local book
local cover_calls = 0

package.preload["lockscreen.components.current"] = function()
    return { book = function(with_stats)
        Assert.is_true(with_stats, "卡片要今日时长和累计时长，必须带统计取书")
        return book
    end }
end

package.preload["lockscreen.render"] = function()
    return { measureText = function(_, _, size) return size end }
end

package.preload["lockscreen.layout"] = function()
    return { panel = function(opts)
        return { x = 0, y = 0, w = opts.screen_w, h = opts.height, pad = 10, text_x = 10, text_w = 80, radius = 8 }
    end }
end

package.preload["lockscreen.components.util"] = function()
    return {
        MUTED = 3,
        chapterLine = function(value) return value.chapter_title or "阅读中" end,
        progress = function(value) return value.percent, "12 / 80 页" end,
        duration = function(seconds) return tostring(seconds) end,
        emptyBlocks = function(rect, title) return { { kind = "panel", empty = title, height = rect.h } } end,
    }
end

package.preload["ui.components.bookinfo"] = function()
    return {
        cover = function(_, _, _, cw, ch)
            cover_calls = cover_calls + 1
            return { getSize = function() return { w = cw, h = ch } end }, cw, ch
        end,
        progressRow = function(width)
            return { getSize = function() return { w = width, h = 20 } end }, 20
        end,
    }
end

package.loaded["lockscreen.components.cards"] = nil
local Cards = require("lockscreen.components.cards")

local function newBook(fields)
    local value = {
        source_id = "moon", stable_id = "b", title = "书", authors = "作者",
        percent = 25, total_seconds = 3600,
        buckets = { { seconds = 100 }, { seconds = 600 } },
    }
    for k, v in pairs(fields or {}) do value[k] = v end
    return value
end

-- 剩余 = 累计 × (1 - 进度) / 进度，与阅读栏同一公式。
Assert.eq(Cards.remainingSeconds(newBook()), 10800)
Assert.is_nil(Cards.remainingSeconds(newBook({ percent = 0 })), "未开读无法外推")
Assert.is_nil(Cards.remainingSeconds(newBook({ percent = 100 })), "已读完不显示剩余")
Assert.is_nil(Cards.remainingSeconds(newBook({ total_seconds = 0 })), "无阅读记录无法外推")
Assert.eq(Cards.todaySeconds(newBook()), 600, "日桶末格是今天")

local rect = { x = 0, y = 0, w = 600, h = 800 }

-- 无在读书籍：居中空态，不画卡片堆。
book = nil
local empty = Cards.stack(rect, { thumb = true, title_size = 20 })
Assert.eq(#empty, 1)
Assert.eq(empty[1].empty, "当前阅读")

-- 胶囊：白卡带阴影，封面缩略图，整堆贴底（最后一张卡底边 = 屏高 - 边距）。
book = newBook()
cover_calls = 0
local blocks = Cards.stack(rect, { thumb = true, title_size = 20 })
Assert.eq(cover_calls, 1)
local panels, texts, bottom = {}, {}, 0
for _, block in ipairs(blocks) do
    if block.kind == "panel" then
        panels[#panels + 1] = block
        bottom = math.max(bottom, block.y + block.height)
    elseif not block.kind then
        texts[block.text] = block
        Assert.is_true(block.box == false, "文字不得自带白底框")
    end
end
Assert.eq(#panels, 4, "书卡 + 进度卡 + 两张指标卡")
Assert.eq(bottom, 800 - math.floor(600 * 0.07))
for _, p in ipairs(panels) do
    Assert.eq(p.shadow, 2)
    Assert.is_nil(p.lighten)
    Assert.is_true(p.y >= 0, "卡片堆不能顶出屏幕")
end
Assert.eq(panels[3].y, panels[4].y, "两张指标卡同一行")
Assert.eq(panels[3].height, panels[4].height)
Assert.not_nil(texts["10800"], "预计剩余")
Assert.not_nil(texts["600"], "今日阅读")
Assert.not_nil(texts["作者"])

-- 封面卡片：半透明无阴影，不放缩略图；无法外推时显示「暂无」。
book = newBook({ percent = 0, authors = "" })
cover_calls = 0
blocks = Cards.stack(rect, { thumb = false, lighten = 0.75, title_size = 24 })
Assert.eq(cover_calls, 0)
texts = {}
for _, block in ipairs(blocks) do
    if block.kind == "panel" then
        Assert.eq(block.lighten, 0.75)
        Assert.is_nil(block.shadow)
    elseif not block.kind then
        texts[block.text] = true
    end
end
Assert.is_true(texts["暂无"])
Assert.is_nil(texts[""], "作者为空时不留空行")
