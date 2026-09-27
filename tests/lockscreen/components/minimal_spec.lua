--[[--
lockscreen 极简：日期、高亮回落默认句、有书才画底部书名与进度。

@module tests.lockscreen.components.minimal_spec
--]]

local Assert = require("support.assert")

local book
local quote

package.preload["lockscreen.components.current"] = function()
    return { book = function() return book end }
end

package.preload["lockscreen.components.highlight"] = function()
    return { next = function() return quote and quote[1], quote and quote[2] end }
end

package.preload["lockscreen.components.quote_panel"] = function()
    return { fit = function(text, _, size) return text, size, 40 end }
end

package.preload["lockscreen.components.cards"] = function()
    return {
        remainingSeconds = function(value) return value.remaining end,
        todaySeconds = function() return 600 end,
    }
end

package.preload["lockscreen.render"] = function()
    return { measureText = function(_, _, size) return size end }
end

package.preload["ui.components.bookinfo"] = function()
    return {
        progressRow = function(width)
            return { getSize = function() return { w = width, h = 20 } end }, 20
        end,
    }
end

package.preload["lockscreen.components.util"] = function()
    return {
        MUTED = 3, RULE = 5,
        FALLBACK_MESSAGE = "默认",
        duration = function(seconds) return tostring(seconds) end,
    }
end

package.loaded["lockscreen.components.minimal"] = nil
local Minimal = require("lockscreen.components.minimal")
Assert.eq(Minimal.uses_background, false, "极简固定白底，不跟随用户背景")

local rect = { x = 0, y = 0, w = 600, h = 800 }

local function texts(blocks)
    local out = {}
    for _, block in ipairs(blocks) do
        if block.text then
            out[#out + 1] = block.text
            Assert.is_true(block.box == false, "文字不得自带白底框")
        end
    end
    return out
end

-- 无书无高亮：日期 + 默认句，不画底部书行。
book, quote = nil, nil
local blocks = Minimal.blocks(rect)
local lines = texts(blocks)
Assert.eq(#blocks, 4)
Assert.eq(lines[3], "默认")
Assert.eq(lines[4], "—— 默认句子")
local now = os.date("*t")
Assert.eq(lines[1], string.format("%d月%d日", now.month, now.day))

-- 有书有高亮：底部书名、今日 / 剩余与进度条贴底。
book = { title = "书名", percent = 30, remaining = 1200 }
quote = { "划线", "第 3 章" }
blocks = Minimal.blocks(rect)
lines = texts(blocks)
Assert.eq(lines[3], "划线")
Assert.eq(lines[4], "—— 第 3 章")
Assert.eq(lines[5], "书名")
Assert.eq(lines[6], "今日阅读 600 · 预计剩余 1200")
local bar = blocks[#blocks]
Assert.eq(bar.kind, "widget")
Assert.eq(bar.y + bar.height, 800 - 60, "进度条贴底边距")

-- 无法外推剩余时只显示今日。
book.remaining = nil
lines = texts(Minimal.blocks(rect))
Assert.eq(lines[6], "今日阅读 600")
