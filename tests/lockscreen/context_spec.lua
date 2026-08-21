--[[--
lockscreen.context：当前书、周期账单与高亮轮换。

@module tests.lockscreen.context_spec
--]]

local Assert = require("support.assert")

local settings = { active_source = "moon", lock_screen_bill_period = "7d" }
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() end }
end

local recent_rows = {
    { source_id = "moon", stable_id = "b1", title = "在读", authors = "甲", percent = 35, last_chapter_idx = 2 },
    { source_id = "moon", stable_id = "b2", title = "读完", authors = "乙", percent = 100 },
    { source_id = "moon", stable_id = "b3", title = "封面书", authors = "丙", percent = 10 },
}
local global_recent = {
    { source_id = "wechat", stable_id = "wrong-source-book", title = "微信源错误书", authors = "错误作者", percent = 10 },
}
local recent_source
package.preload["utils.db.book"] = function()
    return {
        get = function() return { title = "测试书", authors = "作者", percent = 10 } end,
        recent = function() return global_recent end,
        recentBySource = function(source)
            recent_source = source
            return recent_rows
        end,
        listBySource = function()
            return {
                { source_id = "moon", stable_id = "b4", title = "库内书", authors = "丁", percent = 0 },
            }, 1
        end,
    }
end
package.preload["utils.db.progress"] = function()
    return {
        get = function() return { chapter_idx = 3, fraction = 0.35 } end,
    }
end
package.preload["book.store"] = function()
    return { toc = function() return { {}, {}, {}, {} } end }
end
package.preload["utils.paths"] = function()
    return {
        coverPath = function(stable_id)
            return "/covers/" .. tostring(stable_id) .. ".png"
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            if path == "/covers/b1.png" and field == "mode" then
                return "file"
            end
            return nil
        end,
    }
end
local range
local summary_source
package.preload["utils.db.stats"] = function()
    return {
        summaryByBook = function(source)
            summary_source = source
            return { total_seconds = 600 }
        end,
        periodSummary = function(source, start_ts, end_ts)
            range = { source, start_ts, end_ts }
            return { total_seconds = 10, book_count = 1, pages = 2 }
        end,
        periodBooks = function() return { { stable_id = "b1" } } end,
        periodDays = function(_, start_ts)
            if start_ts < os.time() - 300 * 86400 then
                local today = os.date("%Y-%m-%d")
                local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
                return {
                    { ymd = yesterday, seconds = 100, pages = 1 },
                    { ymd = today, seconds = 200, pages = 2 },
                }
            end
            return { { ymd = "2024-01-01", seconds = 10, pages = 1 } }
        end,
        periodHours = function() return { { hour = 9, seconds = 600, pages = 2 } } end,
        dailyByBook = function()
            return { { ymd = "2024-01-01", seconds = 600, pages = 2 } }
        end,
        dailyBySource = function()
            local today = os.date("%Y-%m-%d")
            local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
            return {
                { ymd = yesterday, seconds = 100, pages = 1 },
                { ymd = today, seconds = 200, pages = 2 },
            }
        end,
    }
end
local annotations = {
    { type = "bookmark", text = "忽略" },
    { drawer = "lighten", text = "第一句", chapter = "第3章 序章", pageno = 12 },
    { drawer = "underscore", text = "第二句", pageno = 20 },
}
local session_book
package.preload["ui.reader.session"] = function()
    return {
        current = function() return session_book end,
        toc = function() return nil end,
    }
end

-- 有会话：用会话里的书
session_book = {
    identity = { source_id = "moon", stable_id = "b1" },
    percent = 35, page = 7, total_pages = 20,
    ui = { annotation = { annotations = annotations } },
}
package.loaded["lockscreen.context"] = nil
local Context = require("lockscreen.context")

local book = Context.currentBook()
Assert.eq(book.title, "测试书")
Assert.eq(book.percent, 35)
Assert.is_nil(book.total_seconds)
Assert.is_nil(summary_source)
Assert.eq(book.page, 7)
Assert.eq(book.total_pages, 20)

local book_stats = Context.currentBook(true)
Assert.eq(book_stats.total_seconds, 600)
Assert.eq(summary_source, "moon")
Assert.len(book_stats.buckets, 7)
Assert.eq(book_stats.buckets[1].seconds, 0) -- stub 日不在近 7 天，补齐后为 0

-- 无会话：回退到 last_open 最近未读完的一本，章节来自 pending_progress
session_book = nil
package.loaded["lockscreen.context"] = nil
Context = require("lockscreen.context")
local latest = Context.currentBook()
Assert.eq(latest.title, "在读")
Assert.eq(latest.percent, 35)
Assert.eq(latest.stable_id, "b1")
Assert.eq(latest.chapter_idx, 3)
Assert.eq(latest.chapter_count, 4)
Assert.is_nil(latest.total_seconds)
Assert.eq(recent_source, "moon")

local latest_stats = Context.currentBook(true)
Assert.eq(latest_stats.total_seconds, 600)
Assert.eq(summary_source, "moon")

-- 最近全是读完：仍取 last_open 第一本
settings.active_source = "local"
recent_rows = {
    { source_id = "local", stable_id = "done", title = "刚读完", authors = "", percent = 100 },
}
package.loaded["lockscreen.context"] = nil
Context = require("lockscreen.context")
local finished = Context.currentBook()
Assert.eq(finished.title, "刚读完")
Assert.eq(finished.percent, 100)
Assert.is_nil(finished.total_seconds)
Assert.eq(recent_source, "local")
local finished_stats = Context.currentBook(true)
Assert.eq(finished_stats.total_seconds, 600)
Assert.eq(summary_source, "local")

settings.active_source = "moon"
local bill = Context.bill()
Assert.eq(bill.period, "7d")
Assert.eq(bill.grain, "day")
Assert.eq(range[1], "moon")
Assert.is_true(range[3] > range[2])
Assert.len(bill.books, 1)
Assert.len(bill.buckets, 7)
Assert.eq(bill.buckets[1].seconds, 0) -- stub 日不在本周，补齐后全 0

-- 今日：按小时 24 格
settings.lock_screen_bill_period = "today"
package.loaded["lockscreen.context"] = nil
Context = require("lockscreen.context")
local today_bill = Context.bill()
Assert.eq(today_bill.period, "today")
Assert.eq(today_bill.grain, "hour")
Assert.len(today_bill.buckets, 24)
Assert.eq(today_bill.buckets[10].seconds, 600) -- hour 9 → index 10
settings.lock_screen_bill_period = "7d"
package.loaded["lockscreen.context"] = nil
Context = require("lockscreen.context")

session_book = {
    identity = { source_id = "moon", stable_id = "b1" },
    percent = 35, page = 7, total_pages = 20,
    ui = { annotation = { annotations = annotations } },
}
package.loaded["lockscreen.context"] = nil
Context = require("lockscreen.context")
Assert.eq(Context.highlight(), "第一句")
local text2, source2 = Context.highlight()
Assert.eq(text2, "第二句")
Assert.is_true(tostring(source2):find("20", 1, true) ~= nil)
local text3, source3 = Context.highlight()
Assert.eq(text3, "第一句")
Assert.is_true(tostring(source3):find("序章", 1, true) ~= nil)

-- 无 Reader 会话时，高亮应从本地 notes 回退，而不是直接显示默认句子。
package.preload["utils.db.note"] = function()
    return {
        get = function(_, stable_id)
            if stable_id ~= "b1" then return nil end
            return {
                payload = '[{"drawer":"lighten","text":"数据库高亮","chapter":"第4章","pageno":30}]',
            }
        end,
    }
end
session_book = nil
recent_rows = {
    { source_id = "moon", stable_id = "b1", title = "在读", authors = "甲", percent = 35 },
}
settings.lock_screen_quote_index = nil
package.loaded["utils.db.note"] = nil
package.preload["json"] = function()
    return {
        decode = function()
            return { { drawer = "lighten", text = "数据库高亮", chapter = "第4章", pageno = 30 } }
        end,
    }
end
package.loaded["json"] = nil
package.loaded["lockscreen.context"] = nil
Context = require("lockscreen.context")
Assert.eq(Context.highlight(), "数据库高亮")

recent_rows = {
    { source_id = "moon", stable_id = "b1", title = "在读", authors = "甲", percent = 35 },
    { source_id = "moon", stable_id = "b2", title = "读完", authors = "乙", percent = 100 },
    { source_id = "moon", stable_id = "b3", title = "封面书", authors = "丙", percent = 10 },
}
package.loaded["lockscreen.context"] = nil
Context = require("lockscreen.context")
local shelf = Context.bookshelf()
Assert.len(shelf.reading, 2)
Assert.eq(shelf.reading[1].stable_id, "b1")
Assert.eq(shelf.reading[1].cover, "/covers/b1.png")
Assert.eq(shelf.reading[2].stable_id, "b3")
Assert.is_nil(shelf.reading[2].cover)
Assert.eq(shelf.covers[1].stable_id, "b2")
Assert.eq(shelf.covers[2].stable_id, "b4")
