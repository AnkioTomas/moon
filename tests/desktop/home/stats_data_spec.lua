--[[--
首页统计共用读库：同一次 memo 只扫日表一次；summary 复用日表；今年读完走计数。

@module tests.desktop.home.stats_data_spec
--]]
local Assert = require("support.assert")

local daily_calls, finished_calls = 0, 0
local daily = {
    { ymd = "2026-01-01", seconds = 60, pages = 1 },
    { ymd = "2026-06-01", seconds = 120, pages = 2 },
}
package.preload["book.stats_db"] = function()
    return {
        dailyBySource = function(_scope, start_ts, end_ts)
            daily_calls = daily_calls + 1
            if not start_ts then return daily end
            local out, start_ymd = {}, os.date("%Y-%m-%d", start_ts)
            local end_ymd = end_ts and os.date("%Y-%m-%d", end_ts)
            for _idx, row in ipairs(daily) do
                if row.ymd >= start_ymd and (not end_ymd or row.ymd < end_ymd) then
                    out[#out + 1] = row
                end
            end
            return out
        end,
        summaryBySource = function(_scope, rows)
            local total = 0
            for _idx, row in ipairs(rows or {}) do total = total + row.seconds end
            return { total_seconds = total }
        end,
        finishedCountSince = function()
            finished_calls = finished_calls + 1
            return 3
        end,
    }
end
package.preload["book.catalog"] = function()
    return { libraryScope = function(id) return id end }
end

package.loaded["desktop.pages.home.stats_data"] = nil
local StatsData = require("desktop.pages.home.stats_data")

local memo = {}
local ctx = { source = { id = "owner" }, stats_memo = memo }

daily_calls, finished_calls = 0, 0
local summary, rows = StatsData.summary(ctx)
Assert.eq(summary.total_seconds, 180)
Assert.len(rows, 2)
Assert.eq(daily_calls, 1, "summary 只扫日表一次")

local ranged = StatsData.daily(ctx, os.time{ year = 2026, month = 3, day = 1 }, os.time{ year = 2026, month = 12, day = 1 })
Assert.len(ranged, 1)
Assert.eq(ranged[1].ymd, "2026-06-01")
Assert.eq(daily_calls, 1, "有 memo 时区间过滤不再查库")

Assert.eq(StatsData.finishedYear(ctx, os.time{ year = 2026, month = 6, day = 1 }), 3)
Assert.eq(StatsData.finishedYear(ctx, os.time{ year = 2026, month = 12, day = 1 }), 3)
Assert.eq(finished_calls, 1, "同年读完计数只查一次")

memo.daily = nil
memo.scope_key = nil
local bare = { source = { id = "owner" } }
daily_calls = 0
StatsData.daily(bare, os.time{ year = 2026, month = 3, day = 1 }, os.time{ year = 2026, month = 12, day = 1 })
Assert.eq(daily_calls, 1, "无 memo 直接带时间窗查库")

return true
