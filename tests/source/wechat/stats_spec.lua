--[[-- source.wechat.stats：readdata/detail → reading_stats 行映射。 --]]

local Assert = require("support.assert")
local Stats = require("source.wechat.stats")

do
    local result = Stats.fromWires("wechat", {
        totalReadTime = 7200,
    }, { {
        baseTime = 1_704_067_200,
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
    } })
    Assert.eq(result.replace.mode, "ranges")
    Assert.len(result.replace.ranges, 3)
    local by_id = {}
    for _, row in ipairs(result.rows) do by_id[row.stable_id] = row end
    Assert.eq(by_id[Stats.TOTAL_ID].duration, 7200)
    Assert.eq(by_id["__wr:day:1704067200"].duration, 900,
        "年度日明细必须优先于月度分桶")
    Assert.eq(by_id["__wr:day:1704153600"].duration, 600)
    Assert.is_nil(by_id["__wr:day:1704240000"],
        "年度月桶不能伪装成某一天的时长")
    Assert.is_nil(by_id["__wr:book:42:1704067200"],
        "周期排行不能伪造为按日书籍记录")
end

do
    local january = 1_704_067_200
    local february = 1_706_745_600
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
