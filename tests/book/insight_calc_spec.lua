--[[--
book.insight_calc：环目标自适应、阅读段切分、周对比、趋势（历史不足 / 状态判定）、热力图分级、
月挑战、完成预测、作者排行。纯计算，无 DB。

@module tests.book.insight_calc_spec
--]]

local Assert = require("support.assert")
local Calc = require("book.insight_calc")

local now = os.time{ year = 2026, month = 6, day = 15, hour = 12 }
local function ymd(off) return os.date("%Y-%m-%d", now - off * 86400) end
local function day(seconds, pages) return { duration_seconds = seconds, pages = pages or 0 } end

-- 没历史：环用兜底目标；连续天数当天没读就从昨天算。
local empty = Calc.rings({}, now, ymd(0))
Assert.eq(empty.minutes.target, 30)
Assert.eq(empty.pages.target, 30)
Assert.eq(empty.streak.value, 0)

local days = { [ymd(0)] = day(600, 20), [ymd(1)] = day(3000, 40), [ymd(2)] = day(3000, 40) }
Assert.eq(Calc.streak(days, ymd(0)), 3)
Assert.eq(Calc.streak({ [ymd(1)] = day(60) }, ymd(0)), 1, "今天没读不断连续")
local rings = Calc.rings(days, now, ymd(0))
Assert.eq(rings.minutes.value, 10)
Assert.eq(rings.minutes.target, 50, "近 30 天有读日均 50 分钟")
Assert.eq(rings.pages.value, 20)

-- 阅读段：同书间隔 ≤10 分钟合并，换书或久隔另起。
local t0 = now
local segs = Calc.sessions({
    { source_id = "a", stable_id = "1", start_time = t0, duration = 60, pages = 1 },
    { source_id = "a", stable_id = "1", start_time = t0 + 120, duration = 60, pages = 1 },
    { source_id = "a", stable_id = "2", start_time = t0 + 200, duration = 60, pages = 1 },
    { source_id = "a", stable_id = "2", start_time = t0 + 5000, duration = 60, pages = 1 },
})
Assert.len(segs, 3)
Assert.eq(segs[1].seconds, 120)
Assert.eq(segs[1].pages, 2)
Assert.len(Calc.sessionsOn(segs, ymd(0)), 3)
Assert.len(Calc.sessionsOn(segs, ymd(1)), 0)

-- 周对比：上周为 0 时没有百分比。
local wk = Calc.weekCompare({ [ymd(0)] = day(600) }, now)
Assert.len(wk.bars, 7)
Assert.eq(wk.bars[7].seconds, 600)
Assert.is_nil(wk.change)
wk = Calc.weekCompare({ [ymd(0)] = day(600), [ymd(7)] = day(300) }, now)
Assert.eq(wk.change, 1)

-- 趋势：历史不足 120 天全部 nodata。
Assert.is_false(Calc.trends(days, {}, {}, now).enough)
local long = {}
for off = 1, 200 do long[ymd(off)] = day(off <= 90 and 3600 or 1800, 30) end
local tr = Calc.trends(long, {}, {}, now)
Assert.is_true(tr.enough)
Assert.eq(tr.metrics[1].key, "minutes")
Assert.eq(tr.metrics[1].status, "up")
Assert.eq(tr.metrics[4].status, "nodata", "没有阅读段就没有单次时长")

-- 热力图：53 周 × 7，未来日为 false，有读的日子分级。
local hm = Calc.heatmap({ [ymd(0)] = day(100), [ymd(1)] = day(900) }, now)
Assert.len(hm.cols, 53)
Assert.len(hm.cols[53], 7)
Assert.eq(hm.cols[53][7], false, "本周周日还没到")
local today_cell
for _idx, cell in ipairs(hm.cols[53]) do
    if cell and cell.ymd == ymd(0) then today_cell = cell end
end
Assert.eq(today_cell.level, 1)

-- 月挑战：没历史 nil；有历史目标 = 日均 × 1.1 × 本月天数。
Assert.is_nil(Calc.challenge({}, now))
local custom = Calc.challenge({}, now, 36000)
Assert.eq(custom.target, 36000, "自定义目标没有历史也能用")
Assert.eq(Calc.challenge(long, now, 36000).target, 36000, "自定义目标优先于推算")
local ch = Calc.challenge(long, now)
Assert.is_true(ch.target > 0 and ch.ratio >= 0 and ch.ratio <= 1)

-- 完成预测：按本书速度 / 近 30 天日均。
local reading = { { fraction = 0.5, seconds = 3600, title = "A" } }
local fc = Calc.forecast({ [ymd(0)] = day(3600) }, reading, {}, now)
Assert.eq(fc.books[1].days_left, 30, "还剩 3600 秒，日均 120 秒")
Assert.len(Calc.forecast({}, reading, {}, now).books, 0)

-- 排行：作者可含多人，本数优先。
local fin = {
    { authors = "甲, 乙", category = "科幻", seconds = 100, last_time = now },
    { authors = "甲", category = "科幻/历史", seconds = 50, last_time = now },
    { authors = "", seconds = 0, last_time = now },
}
local authors = Calc.top(fin, "authors", 5)
Assert.eq(authors[1].name, "甲")
Assert.eq(authors[1].count, 2)
Assert.len(authors, 2)
Assert.eq(Calc.top(fin, "category", 5)[1].name, "科幻")
local cjk = Calc.top({ { category = "科技、历史，文学；悬疑", seconds = 1 } }, "category", 9)
Assert.len(cjk, 4, "多字节分隔符不能切坏汉字")
local names = {}
for _idx, e in ipairs(cjk) do names[e.name] = true end
Assert.is_true(names["科技"] and names["文学"] and names["悬疑"] and names["历史"])
Assert.eq(Calc.longest(fin, 5)[1].seconds, 100)
Assert.len(Calc.longest(fin, 5), 2)

-- 年月合计。
local sum = Calc.sum(long, os.date("%Y", now))
Assert.is_true(sum.days > 0)
Assert.eq(Calc.sum({}, "2026").days, 0)

return true
