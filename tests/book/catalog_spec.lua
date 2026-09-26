--[[--
book.catalog：本地唯一读入口离线用例。

@module tests.book.catalog_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local mixed_on = false
local seen_scope
local FakeBooks = {
    list_rows = {},
    list_count = 0,
    categories = {},
    category_counts = {},
    series_counts = {},
    read_counts = {},
    source_counts = {},
    series = {},
    recent = {},
    list_opts = nil,
    meta = nil,
}
local FakeStats = {
    summary = { total_seconds = 0 },
    daily = {},
    daily_books = {},
}

package.preload["utils.settings"] = function()
    return { libraryMixed = function() return mixed_on end }
end
package.preload["source.registry"] = function()
    return {
        list = function()
            return {
                { id = "local", name = "本地书籍", type = "book" },
                { id = "wechat", name = "微信读书", type = "chapter" },
            }
        end,
        listEnabled = function()
            return {
                { id = "local", name = "本地书籍" },
                { id = "wechat", name = "微信读书" },
            }
        end,
    }
end
package.preload["db.book"] = function()
    return {
        listBySource = function(scope, opts)
            seen_scope = scope
            FakeBooks.list_opts = opts
            return FakeBooks.list_rows, FakeBooks.list_count
        end,
        categoriesBySource = function() return FakeBooks.categories end,
        categoryCountsBySource = function() return FakeBooks.category_counts end,
        seriesCountsBySource = function() return FakeBooks.series_counts end,
        readStatusCountsBySource = function() return FakeBooks.read_counts end,
        downloadedCountBySource = function(_, chapter_sources)
            FakeBooks.count_chapter_sources = chapter_sources
            return 3
        end,
        seriesBySource = function() return FakeBooks.series end,
        sourceCountsBySource = function() return FakeBooks.source_counts end,
        get = function(source_id, stable_id)
            return FakeBooks.meta and FakeBooks.meta[source_id .. "\n" .. tostring(stable_id)]
        end,
    }
end
package.preload["db.progress"] = function()
    return {
        recent = function(scope)
            seen_scope = scope
            return FakeBooks.recent
        end,
    }
end
package.preload["db.stats"] = function()
    return {
        summaryBySource = function() return FakeStats.summary end,
        dailyBySource = function() return FakeStats.daily end,
        dailyBooksBySource = function() return FakeStats.daily_books end,
        weeklyBooksBySource = function() return {} end,
    }
end
package.loaded["book.catalog"] = nil

local Catalog = require("book.catalog")

do -- toList 带 source_id
    local list = Catalog.toList({
        { stable_id = "a.epub", title = "A", percent = 10, path = "/cache/a.epub" },
    }, 3, "moon")
    Assert.eq(list.count, 3)
    Assert.eq(list.data[1].source_id, "moon")
    Assert.eq(list.data[1].title, "A")
    Assert.eq(list.data[1].path, "/cache/a.epub")
end

do -- listLibraryAsync 读假库
    FakeBooks.list_rows = { { stable_id = "b.epub", title = "B" } }
    FakeBooks.list_count = 1
    local got
    Catalog.listLibraryAsync("local", {
        page = 1, page_size = 10, read_status = "unread",
    }, function(res, err)
        got = { res = res, err = err }
    end)
    Stubs.flush()
    Assert.is_nil(got.err)
    Assert.eq(got.res.count, 1)
    Assert.eq(got.res.data[1].source_id, "local")
    Assert.eq(got.res.data[1].title, "B")
    Assert.eq(FakeBooks.list_opts.read_status, "unread")
    Assert.is_nil(FakeBooks.list_opts.chapter_sources)
    Assert.eq(seen_scope, "local")

    Catalog.listLibraryAsync("local", { downloaded = true }, function() end)
    Stubs.flush()
    Assert.is_true(FakeBooks.list_opts.downloaded)
    Assert.eq(#FakeBooks.list_opts.chapter_sources, 1)
    Assert.eq(FakeBooks.list_opts.chapter_sources[1], "wechat")
end

do -- filtersAsync
    FakeBooks.categories = { "科幻" }
    FakeBooks.category_counts = { { category = "科幻", count = 2 } }
    FakeBooks.series_counts = { { series = "三体", count = 2 } }
    FakeBooks.read_counts = { { status = "read", count = 1 } }
    FakeBooks.series = { "三体" }
    local got
    Catalog.filtersAsync("local", function(res)
        got = res
    end)
    Stubs.flush()
    Assert.eq(got.data.category[1], "科幻")
    Assert.eq(got.data.category_counts[1].count, 2)
    Assert.eq(got.data.series_counts[1].series, "三体")
    Assert.eq(got.data.read_counts[1].status, "read")
    Assert.eq(got.data.series[1], "三体")
    Assert.eq(got.data.downloaded_count, 3)
    Assert.eq(FakeBooks.count_chapter_sources[1], "wechat")
    Assert.is_nil(got.data.source_counts)
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

do -- 混合模式：多源 scope 下发给 DB，行上保留真实 source_id
    mixed_on = true
    FakeBooks.list_rows = {
        { source_id = "local", stable_id = "a.epub", title = "A" },
        { source_id = "wechat", stable_id = "b", title = "B" },
    }
    FakeBooks.list_count = 2
    FakeBooks.recent = {
        { source_id = "wechat", stable_id = "b", fraction = 0.5, updated_at = 2 },
        { source_id = "local", stable_id = "a.epub", fraction = 0.1, updated_at = 1 },
    }
    FakeBooks.meta = {
        ["wechat\nb"] = { source_id = "wechat", stable_id = "b", title = "B" },
        ["local\na.epub"] = { source_id = "local", stable_id = "a.epub", title = "A" },
    }
    FakeBooks.source_counts = {
        { source_id = "local", count = 3 },
        { source_id = "wechat", count = 5 },
    }

    local got
    Catalog.listLibraryAsync("local", { page = 1, page_size = 10 }, function(res, err)
        got = { res = res, err = err }
    end)
    Stubs.flush()
    Assert.is_nil(got.err)
    Assert.eq(seen_scope[1], "local")
    Assert.eq(seen_scope[2], "wechat")
    Assert.eq(got.res.data[1].source_id, "local")
    Assert.eq(got.res.data[2].source_id, "wechat")

    Catalog.listLibraryAsync("local", {
        page = 1, page_size = 10, source_id = "wechat",
    }, function(res, err)
        got = { res = res, err = err }
    end)
    Stubs.flush()
    Assert.eq(FakeBooks.list_opts.source_id, "wechat")
    Assert.eq(seen_scope[1], "local")

    local filters
    Catalog.filtersAsync("local", function(res) filters = res end)
    Stubs.flush()
    Assert.eq(filters.data.source_counts[1].source_id, "local")
    Assert.eq(filters.data.source_counts[1].name, "本地书籍")
    Assert.eq(filters.data.source_counts[1].count, 3)
    Assert.eq(filters.data.source_counts[2].source_id, "wechat")
    Assert.eq(filters.data.source_counts[2].name, "微信读书")
    Assert.eq(filters.data.source_counts[2].count, 5)

    local recent = Catalog.recentBooks("local", 24)
    Assert.eq(seen_scope[1], "local")
    Assert.eq(recent[1].source_id, "wechat")
    Assert.eq(recent[1].percent, 50)
    Assert.eq(recent[2].source_id, "local")
    mixed_on = false
end
