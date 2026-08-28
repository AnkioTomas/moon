--[[-- source.wechat.stats：readdata/detail → reading_stats 行映射。 --]]

local Assert = require("support.assert")
local Stats = require("source.wechat.stats")

do
    local result = Stats.fromWire("wechat", {
        baseTime = 1_700_000_000,
        readTimes = {
            ["1700000000"] = 1800,
            ["1700086400"] = 600,
        },
        readLongest = {
            { book = { bookId = "42" }, readTime = 3600 },
        },
    })
    Assert.eq(result.replace.mode, "synced")
    Assert.eq(#result.rows, 3)
    local by_id = {}
    for _, row in ipairs(result.rows) do
        by_id[row.stable_id] = row
    end
    Assert.eq(by_id["__wr:day:1700000000"].duration, 1800)
    Assert.eq(by_id["__wr:day:1700086400"].duration, 600)
    Assert.eq(by_id["__wr:book:42:1700000000"].duration, 3600)
    Assert.eq(by_id["__wr:book:42:1700000000"].start_time, 1_700_000_000)
end

do
    local result = Stats.fromWire("wechat", {})
    Assert.eq(#result.rows, 0)
    Assert.eq(result.replace.mode, "synced")
end
