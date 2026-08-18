--[[--
utils.db.stats：账单周期查询必须参数化并正确映射结果。

@module tests.utils.db.stats_period_spec
--]]

local Assert = require("support.assert")
local calls = {}

package.preload["utils.db.base"] = function()
    return {
        requireSourceId = function(id) return id ~= "" and id or nil end,
        ensure = function() end,
        rowexec = function(sql, ...)
            calls[#calls + 1] = { sql = sql, args = { ... } }
            return 3600, 2, 9
        end,
        query = function(sql, ...)
            calls[#calls + 1] = { sql = sql, args = { ... } }
            if sql:find("date(start_time", 1, true) then
                return { { "2024-01-01" }, { 600 }, { 2 } }, 1
            end
            return {
                { "b1" }, { "书名" }, { "作者" }, { 42 }, { 1800 }, { 5 },
            }, 1
        end,
    }
end
package.loaded["utils.db.stats"] = nil

local Stats = require("utils.db.stats")
local summary = Stats.periodSummary("moon", 100, 200)
Assert.eq(summary.total_seconds, 3600)
Assert.eq(summary.book_count, 2)
Assert.eq(summary.pages, 9)
Assert.eq(calls[1].args[1], "moon")
Assert.eq(calls[1].args[2], 100)
Assert.eq(calls[1].args[3], 200)

local books = Stats.periodBooks("moon", 100, 200, 3)
Assert.len(books, 1)
Assert.eq(books[1].stable_id, "b1")
Assert.eq(books[1].seconds, 1800)
Assert.eq(books[1].percent, 42)
Assert.eq(calls[2].args[4], 3)
Assert.is_true(calls[2].sql:find("start_time>=?", 1, true) ~= nil)

local days = Stats.periodDays("moon", 100, 200)
Assert.len(days, 1)
Assert.eq(days[1].ymd, "2024-01-01")
Assert.eq(days[1].seconds, 600)
