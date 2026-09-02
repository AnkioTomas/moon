--[[--
lockscreen 当前阅读：所有书籍数据只读当前源数据库。

@module tests.lockscreen.components.current_spec
--]]

local Assert = require("support.assert")

local active_source = "moon"
local book_source
local progress_source
local progress_stable_id
local progress_value = {
    fraction = 0.55,
    chapter_idx = 7,
    chapter_title = "数据库章节",
    page = 12,
    total_pages = 80,
}
local stats_sources = {}
local rows = {
    { stable_id = "done", title = "Done", authors = "A", percent = 100 },
    { stable_id = "reading", title = "Reading", authors = "B", percent = 40 },
}

package.preload["db.book"] = function()
    return {
        recentBySource = function(source_id, limit)
            book_source = source_id
            Assert.eq(limit, 16)
            return rows
        end,
    }
end

package.preload["db.progress"] = function()
    return {
        get = function(source_id, stable_id)
            progress_source = source_id
            progress_stable_id = stable_id
            return progress_value
        end,
    }
end

package.preload["db.stats"] = function()
    return {
        summaryByBook = function(source_id, stable_id)
            stats_sources[#stats_sources + 1] = source_id
            Assert.eq(stable_id, "reading")
            return { total_seconds = 3600 }
        end,
        dailyByBook = function(source_id, stable_id, limit)
            stats_sources[#stats_sources + 1] = source_id
            Assert.eq(stable_id, "reading")
            Assert.eq(limit, 7)
            return {}
        end,
    }
end

package.preload["lockscreen.components.library"] = function()
    return {
        activeSourceId = function() return active_source end,
        coverPath = function(stable_id, source_id)
            return source_id .. "/" .. stable_id .. ".png"
        end,
    }
end

package.preload["lockscreen.components.util"] = function()
    return {
        dayStart = function() return 100000 end,
        dayBuckets = function() return { { key = "today" } } end,
    }
end

package.preload["ui.reader.session"] = function()
    error("lockscreen current must not read ReaderSession")
end

package.loaded["lockscreen.components.current"] = nil
local Current = require("lockscreen.components.current")
local book = assert(Current.book(true))

Assert.eq(book_source, "moon")
Assert.eq(progress_source, "moon")
Assert.eq(progress_stable_id, "reading")
Assert.eq(stats_sources[1], "moon")
Assert.eq(stats_sources[2], "moon")
Assert.eq(book.source_id, "moon")
Assert.eq(book.stable_id, "reading")
Assert.eq(book.title, "Reading")
Assert.eq(book.authors, "B")
Assert.eq(math.floor(book.percent + 0.5), 55)
Assert.eq(book.chapter_idx, 7)
Assert.eq(book.chapter_title, "数据库章节")
Assert.eq(book.page, 12)
Assert.eq(book.total_pages, 80)
Assert.eq(book.cover, "moon/reading.png")
Assert.eq(book.total_seconds, 3600)
Assert.eq(book.buckets[1].key, "today")

-- books 行不存在章节字段；即使测试数据夹带旧字段也不得读取。
rows = {
    {
        stable_id = "poison",
        title = "Poison",
        percent = 20,
        last_chapter_idx = 99,
        chapter_title = "错误字段",
    },
}
progress_value = {}
book = assert(Current.book())
Assert.eq(book.stable_id, "poison")
Assert.is_nil(book.chapter_idx)
Assert.is_nil(book.chapter_title)

-- 当前源没有图书时不得回退到其它源或 ReaderSession。
active_source = "wechat"
rows = {}
book_source = nil
Assert.is_nil(Current.book())
Assert.eq(book_source, "wechat")
