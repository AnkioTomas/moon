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
            if sql:find("strftime('%H'", 1, true) then
                return { { 9 }, { 1200 }, { 3 } }, 1
            end
            if sql:find("date(start_time", 1, true) then
                -- 同一天既有云端日桶又有本地逐页记录：合并后只能算云端那份
                return {
                    { "2024-01-01", "2024-01-01" },
                    { "__moon:day:2024-01-01", "b1" },
                    { 3000, 600 },
                    { 1, 2 },
                }, 2
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
-- 总时长走「云端日桶优先」，不是 3000+600
Assert.eq(summary.total_seconds, 3000)
Assert.eq(summary.book_count, 2)
Assert.eq(summary.pages, 9)
Assert.eq(calls[1].args[1], "moon")
Assert.eq(calls[1].args[2], 100)
Assert.eq(calls[1].args[3], 200)
-- 书数/页数只数真实书的记录
Assert.is_true(calls[1].sql:find("NOT GLOB '__*:day:*'", 1, true) ~= nil)

calls = {}
local books = Stats.periodBooks("moon", 100, 200, 3)
Assert.len(books, 1)
Assert.eq(books[1].stable_id, "b1")
Assert.eq(books[1].seconds, 1800)
Assert.eq(books[1].percent, 42)
Assert.eq(calls[1].args[4], 3)
Assert.is_true(calls[1].sql:find("start_time>=?", 1, true) ~= nil)
Assert.is_true(calls[1].sql:find("NOT GLOB '__*:day:*'", 1, true) ~= nil)

calls = {}
local days = Stats.periodDays("moon", 100, 200)
Assert.len(days, 1)
Assert.eq(days[1].ymd, "2024-01-01")
Assert.eq(days[1].seconds, 3000)
Assert.eq(calls[1].args[2], 100, "按天查询必须带范围参数")

local hours = Stats.periodHours("moon", 100, 200)
Assert.len(hours, 1)
Assert.eq(hours[1].hour, 9)
Assert.eq(hours[1].seconds, 1200)
Assert.eq(hours[1].pages, 3)
Assert.is_true(calls[#calls].sql:find("strftime('%H'", 1, true) ~= nil)
Assert.eq(calls[#calls].args[1], "moon")
Assert.eq(calls[#calls].args[2], 100)
Assert.eq(calls[#calls].args[3], 200)
