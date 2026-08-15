--[[--
reader.bars 离线用例：时间 / 进度文案生成。

@module tests.reader.bars_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

local Bars = require("reader.bars")

-- timeText：HH:MM
Assert.is_true(Bars.timeText(0):match("^%d%d:%d%d$") ~= nil)
Assert.is_true(Bars.timeText():match("^%d%d:%d%d$") ~= nil)

-- progressText：空输入
Assert.eq(Bars.progressText(nil), "")
Assert.eq(Bars.progressText({}), "0%")

-- progressText：百分比夹紧
Assert.eq(Bars.progressText({ percent = 42 }), "42%")
Assert.eq(Bars.progressText({ percent = 150 }), "100%")
Assert.eq(Bars.progressText({ percent = -3 }), "0%")

-- progressText：页码 / 章号拼接
Assert.eq(Bars.progressText({ percent = 42, page = 7, total_pages = 100 }), "42% · 第 7/100 页")
Assert.eq(Bars.progressText({ percent = 5, chapter_idx = 3, chapter_count = 10 }), "5% · 第 3/10 章")
Assert.eq(
    Bars.progressText({ percent = 5, page = 1, total_pages = 2, chapter_idx = 3, chapter_count = 10 }),
    "5% · 第 1/2 页 · 第 3/10 章"
)

-- progressText：页数缺失/为零不拼页码
Assert.eq(Bars.progressText({ percent = 1, page = 3 }), "1%")
Assert.eq(Bars.progressText({ percent = 1, page = 3, total_pages = 0 }), "1%")
