--[[--
lockscreen.context：当前书、周期账单与高亮轮换。

@module tests.lockscreen.context_spec
--]]

local Assert = require("support.assert")

local settings = { active_source = "moon", lock_screen_bill_period = "7d" }
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end
package.preload["utils.db.book"] = function()
    return { get = function() return { title = "测试书", authors = "作者", percent = 10 } end }
end
local range
package.preload["utils.db.stats"] = function()
    return {
        summaryByBook = function() return { total_seconds = 600 } end,
        periodSummary = function(source, start_ts, end_ts)
            range = { source, start_ts, end_ts }
            return { total_seconds = 10, book_count = 1, pages = 2 }
        end,
        periodBooks = function() return { { stable_id = "b1" } } end,
        periodDays = function() return { { ymd = "2024-01-01", seconds = 10, pages = 1 } } end,
    }
end
local annotations = {
    { type = "bookmark", text = "忽略" },
    { drawer = "lighten", text = "第一句" },
    { drawer = "underscore", text = "第二句" },
}
package.preload["ui.reader.session"] = function()
    return {
        current = function()
            return {
                identity = { source_id = "moon", stable_id = "b1" },
                percent = 35, page = 7, total_pages = 20,
                ui = { annotation = { annotations = annotations } },
            }
        end,
        toc = function()
            return nil
        end,
    }
end
package.loaded["lockscreen.context"] = nil

local Context = require("lockscreen.context")
local book = Context.currentBook()
Assert.eq(book.title, "测试书")
Assert.eq(book.percent, 35)
Assert.eq(book.total_seconds, 600)

local bill = Context.bill()
Assert.eq(bill.period, "7d")
Assert.eq(range[1], "moon")
Assert.is_true(range[3] > range[2])
Assert.len(bill.books, 1)
Assert.len(bill.days, 1)

Assert.eq(Context.highlight(), "第一句")
Assert.eq(Context.highlight(), "第二句")
Assert.eq(Context.highlight(), "第一句")
