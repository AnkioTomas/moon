--[[--
ui.reader.bars 离线用例：时间 / 进度文案生成。

@module tests.ui.reader.bars_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local settings = {
    ui_scale = 130,
    book_reader_show_top_time = true,
    book_reader_show_bottom_progress = true,
}
package.preload["device"] = function()
    return { screen = { scaleBySize = function(_, n) return n end } }
end
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end
package.preload["ui/event"] = function()
    return { new = function(_, name, arg) return { name = name, arg = arg } end }
end

local Bars = require("ui.reader.bars")

-- timeText：HH:MM
Assert.is_true(Bars.timeText(0):match("^%d%d:%d%d$") ~= nil)
Assert.is_true(Bars.timeText():match("^%d%d:%d%d$") ~= nil)

-- chapterTitle：按章书籍取章节标题，整本书回退书名，缺身份为空
local toc = {}
for i = 1, 10 do toc[i] = { idx = i, title = "第 " .. i .. " 章" } end
Assert.eq(Bars.chapterTitle(nil, toc), "")
Assert.eq(Bars.chapterTitle({}, toc), "")
Assert.eq(Bars.chapterTitle({ identity = { chapter_idx = 3 } }, toc), "第 3 章")
Assert.eq(Bars.chapterTitle({ identity = { book = { title = "书名" } } }, toc), "书名")

-- progressText：空输入
Assert.eq(Bars.progressText(nil), "")
Assert.eq(Bars.progressText({}), "0%")

-- progressText：百分比夹紧
Assert.eq(Bars.progressText({ percent = 42 }), "42%")
Assert.eq(Bars.progressText({ percent = 150 }), "100%")
Assert.eq(Bars.progressText({ percent = -3 }), "0%")

-- progressText：页码 / 章号拼接
Assert.eq(Bars.progressText({ percent = 42, page = 7, total_pages = 100 }), "42% · 第 7/100 页")
Assert.eq(Bars.progressText({ percent = 5, identity = { chapter_idx = 3 } }, toc), "5% · 第 3/10 章")
Assert.eq(
    Bars.progressText({ percent = 5, page = 1, total_pages = 2, identity = { chapter_idx = 3 } }, toc),
    "5% · 第 3/10 章 · 第 1/2 页"
)

-- progressText：页数缺失/为零不拼页码
Assert.eq(Bars.progressText({ percent = 1, page = 3 }), "1%")
Assert.eq(Bars.progressText({ percent = 1, page = 3, total_pages = 0 }), "1%")

-- progressText：剩余阅读时间拼接在末尾
Assert.eq(
    Bars.progressText({ percent = 42, page = 7, total_pages = 100 }, nil, 3600 + 1800),
    "42% · 第 7/100 页 · 约 1 小时 30 分"
)

-- remainingText：不足一分钟为空；分钟 / 小时 + 分钟
Assert.eq(Bars.remainingText(nil), "")
Assert.eq(Bars.remainingText(59), "")
Assert.eq(Bars.remainingText(60), "约 1 分钟")
Assert.eq(Bars.remainingText(5400), "约 1 小时 30 分")

-- insets：按顶/底条开关返回预留高度
local insets = Bars.insets()
Assert.is_true(insets.top > 0)
Assert.is_true(insets.bottom > 0)
settings.book_reader_show_top_time = false
settings.book_reader_show_bottom_progress = false
insets = Bars.insets()
Assert.eq(insets.top, 0)
Assert.eq(insets.bottom, 0)

-- applyInsets：基础 margin 加预留，用 SetPageTopAndBottomMargin 一次下发
settings.book_reader_show_top_time = true
settings.book_reader_show_bottom_progress = true
insets = Bars.insets()
local events = {}
local ui = {
    font = { configurable = { t_page_margin = 14, b_page_margin = 20 } },
    handleEvent = function(_, event) events[#events + 1] = event end,
}
Bars.applyInsets(ui)
Assert.eq(events[1].name, "SetPageTopAndBottomMargin")
Assert.eq(events[1].arg[1], 14 + insets.top)
Assert.eq(events[1].arg[2], 20 + insets.bottom)
