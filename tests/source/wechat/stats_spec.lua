--[[-- source.wechat.stats：readdata/detail → reading_stats 行映射。 --]]

local Assert = require("support.assert")
local Stats = require("source.wechat.stats")

do
    local result = Stats.fromWires("wechat", {
        totalReadTime = 7200,
    }, { {
        baseTime = 1704067200,
        readTimes = {
            ["1704067200"] = 9999,
            ["1704240000"] = 8888,
        },
        dailyReadTimes = {
            ["1704067200"] = 900,
            ["1704153600"] = 600,
        },
        readLongest = {
            { book = { bookId = "42" }, readTime = 1500 },
        },
    } }, nil, nil, 1800000000)
    Assert.eq(result.replace.mode, "ranges")
    Assert.len(result.replace.ranges, 3)
    local legacy_week
    for _, range in ipairs(result.replace.ranges) do
        if range.stable_prefix == "__wr:week:" then legacy_week = range end
    end
    Assert.eq(legacy_week.from_ts, 0, "旧周排行行必须整段清掉")
    Assert.eq(legacy_week.to_ts, 1800000000)
    local by_id = {}
    for _, row in ipairs(result.rows) do by_id[row.stable_id] = row end
    Assert.eq(by_id[Stats.TOTAL_ID].duration, 7200)
    Assert.eq(by_id["__wr:day:1704067200"].duration, 900,
        "年度日明细必须优先于月度分桶")
    Assert.eq(by_id["__wr:day:1704153600"].duration, 600)
    Assert.is_nil(by_id["__wr:day:1704240000"],
        "年度月桶不能伪装成某一天的时长")
    for _, row in ipairs(result.rows) do
        Assert.is_true(row.record_type ~= "book", "周期排行不再落库")
    end
end

do
    local january = 1704067200
    local february = 1706745600
    local annual = {
        readTimes = {
            [tostring(january)] = 1200,
            [tostring(february)] = 0,
        },
    }
    local bases = Stats.monthlyBaseTimes(annual)
    Assert.len(bases, 1)
    Assert.eq(bases[1], january)

    local result = Stats.fromWires("wechat", {
        totalReadTime = 1200,
    }, { annual }, { {
        readTimes = {
            [tostring(january + 86400)] = 1200,
        },
    } })
    local by_id = {}
    for _, row in ipairs(result.rows) do by_id[row.stable_id] = row end
    Assert.eq(by_id["__wr:day:" .. tostring(january + 86400)].duration, 1200)
end

-- changedBooks：只挑云端累计与本地快照不同的书，按更新时间倒序截断到 limit
do
    local changed = Stats.changedBooks({
        { bookId = "a", readingTime = 100, updateTime = 1 },
        { bookId = "b", readingTime = 200, updateTime = 3 },
        { bookId = "c", readingTime = 300, updateTime = 2 },
        { bookId = "same", readingTime = 50, updateTime = 9 },
        { bookId = "never", updateTime = 8 },
    }, { same = 50 }, 2)
    Assert.len(changed, 2)
    Assert.eq(changed[1].id, "b")
    Assert.eq(changed[2].id, "c")
    Assert.len(Stats.changedBooks(nil, {}, 20), 0)
    -- 云端清零（缺 readingTime）而本地有快照：也算变化，要去清掉旧明细
    local cleared = Stats.changedBooks({ { bookId = "gone" } }, { gone = 10 }, 20)
    Assert.eq(cleared[1].reading_time, 0)
    local rows = Stats.fromWires("wechat", {}, {}, nil, {
        { id = "gone", reading_time = 0, wire = {} },
    }, 1000).rows
    Assert.len(rows, 0, "累计为 0 不写快照，靠 replace.books 清旧行")
end
