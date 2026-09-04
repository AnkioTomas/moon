--[[--
book.catalog：本地唯一读入口离线用例。

@module tests.book.catalog_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local FakeBooks = {
    list_rows = {},
    list_count = 0,
    categories = {},
    series = {},
    recent = {},
}
local FakeStats = {
    summary = { total_seconds = 0 },
    daily = {},
    daily_books = {},
}

package.preload["db.book"] = function()
    return {
        listBySource = function()
            return FakeBooks.list_rows, FakeBooks.list_count
        end,
        categoriesBySource = function()
            return FakeBooks.categories
        end,
        seriesBySource = function()
            return FakeBooks.series
        end,
        getMany = function(source_id, stable_ids)
            local out = {}
            for _, stable_id in ipairs(stable_ids) do
                out[stable_id] = FakeBooks.meta
                    and FakeBooks.meta[source_id .. "\n" .. tostring(stable_id)]
            end
            return out
        end,
        get = function(source_id, stable_id)
            return FakeBooks.meta and FakeBooks.meta[source_id .. "\n" .. tostring(stable_id)]
        end,
    }
end
package.preload["db.progress"] = function()
    return {
        recent = function()
            return FakeBooks.recent
        end,
    }
end
package.preload["db.stats"] = function()
    return {
        summaryBySource = function()
            return FakeStats.summary
        end,
        dailyBySource = function()
            return FakeStats.daily
        end,
        dailyBooksBySource = function()
            return FakeStats.daily_books
        end,
    }
end
package.loaded["book.catalog"] = nil

local Catalog = require("book.catalog")

do -- toList 带 source_id
    local list = Catalog.toList({
        { stable_id = "a.epub", title = "A", percent = 10 },
    }, 3, "moon")
    Assert.eq(list.count, 3)
    Assert.eq(list.data[1].source_id, "moon")
    Assert.eq(list.data[1].title, "A")
end

do -- listLibraryAsync 读假库
    FakeBooks.list_rows = { { stable_id = "b.epub", title = "B" } }
    FakeBooks.list_count = 1
    local got
    Catalog.listLibraryAsync("local", { page = 1, page_size = 10 }, function(res, err)
        got = { res = res, err = err }
    end)
    Stubs.flush()
    Assert.is_nil(got.err)
    Assert.eq(got.res.count, 1)
    Assert.eq(got.res.data[1].source_id, "local")
    Assert.eq(got.res.data[1].title, "B")
end

do -- filtersAsync
    FakeBooks.categories = { "科幻" }
    FakeBooks.series = { "三体" }
    local got
    Catalog.filtersAsync("local", function(res)
        got = res
    end)
    Stubs.flush()
    Assert.eq(got.data.category[1], "科幻")
    Assert.eq(got.data.series[1], "三体")
end

do -- recentBooksAsync：进度定顺序和位置，books 只补元数据
    FakeBooks.recent = {
        { source_id = "local", stable_id = "b.epub", fraction = 0.75,
            chapter_idx = 3, chapter_title = "第三章", updated_at = 200 },
        { source_id = "local", stable_id = "a.epub", fraction = 0.25, updated_at = 100 },
    }
    FakeBooks.meta = {
        ["local\nb.epub"] = { stable_id = "b.epub", title = "B", percent = 1 },
        ["local\na.epub"] = { stable_id = "a.epub", title = "A", percent = 99 },
    }
    local got
    Catalog.recentBooksAsync("local", 24, function(res) got = res end)
    Stubs.flush()
    Assert.eq(got.data[1].stable_id, "b.epub")
    Assert.eq(got.data[1].percent, 75)
    Assert.eq(got.data[1].chapter_idx, 3)
    Assert.eq(got.data[1].chapter_title, "第三章")
    Assert.eq(got.data[2].stable_id, "a.epub")
end

do -- readingInsightAsync
    FakeStats.summary = { total_seconds = 120, total_pages = 3 }
    FakeStats.daily = { { ymd = "2026-08-21", seconds = 120 } }
    FakeStats.daily_books = {
        { ymd = "2026-08-21", stable_id = "c.epub", max_page = 2, max_total_pages = 10 },
    }
    FakeBooks.meta = { ["local\nc.epub"] = { title = "C", authors = "作者" } }
    local got
    Catalog.readingInsightAsync("local", function(res)
        got = res
    end)
    Stubs.flush()
    Assert.is_true(got.data.has_data)
    Assert.eq(got.data.calendar.days["2026-08-21"].books[1].title, "C")
    Assert.eq(got.data.calendar.days["2026-08-21"].books[1].percent, 20)
end

do -- 非法 source_id
    local got
    Catalog.listLibraryAsync("", nil, function(res, err)
        got = { res = res, err = err }
    end)
    Stubs.flush()
    Assert.is_nil(got.res)
    Assert.eq(got.err, "invalid source_id")
end

package.preload["db.book"] = nil
package.preload["db.progress"] = nil
package.preload["db.stats"] = nil
package.loaded["db.book"] = nil
package.loaded["db.progress"] = nil
package.loaded["db.stats"] = nil
package.loaded["book.catalog"] = nil
