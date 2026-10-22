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
    return { get = function() return { library_mixed = mixed_on } end }
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
package.preload["book.books_db"] = function()
    return {
        countsBy = function(column) return FakeBooks[column .. "_counts"] end,
        readStatusCountsBySource = function() return FakeBooks.read_counts end,
        downloadedCountBySource = function(_, chapter_sources)
            FakeBooks.count_chapter_sources = chapter_sources
            return 3
        end,
        hiddenCountBySource = function() return 2 end,
        sourceCountsBySource = function() return FakeBooks.source_counts end,
        get = function(source_id, stable_id)
            return FakeBooks.meta and FakeBooks.meta[source_id .. "\n" .. tostring(stable_id)]
        end,
        isDownloaded = function(source_id, stable_id, chapter)
            FakeBooks.downloaded_asks = FakeBooks.downloaded_asks or {}
            FakeBooks.downloaded_asks[#FakeBooks.downloaded_asks + 1] = { source_id, stable_id, chapter }
            return source_id == "local"
        end,
    }
end
package.preload["book.progress_db"] = function()
    return {
        recent = function(scope)
            seen_scope = scope
            return FakeBooks.recent
        end,
    }
end
package.preload["book.stats_db"] = function()
    return {
        summaryBySource = function() return FakeStats.summary end,
        dailyBySource = function() return FakeStats.daily end,
        dailyBooksBySource = function() return FakeStats.daily_books end,
        hourlyBySource = function() return FakeStats.hourly end,
        sessionRows = function() return {} end,
        progressBooks = function() return {} end,
    }
end
package.loaded["book.catalog"] = nil

local Catalog = require("book.catalog")
-- 书库 SQL 本身见 catalog_list_spec；这里只验证异步包装传参。
Catalog.listBooks = function(scope, opts)
    seen_scope = scope
    FakeBooks.list_opts = opts
    return FakeBooks.list_rows, FakeBooks.list_count
end

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
        page = 1, page_size = 10, read_status = "unread", author = "鲁迅", unauthor = false,
    }, function(res, err)
        got = { res = res, err = err }
    end)
    Stubs.flush()
    Assert.is_nil(got.err)
    Assert.eq(got.res.count, 1)
    Assert.eq(got.res.data[1].source_id, "local")
    Assert.eq(got.res.data[1].title, "B")
    Assert.eq(FakeBooks.list_opts.read_status, "unread")
    Assert.eq(FakeBooks.list_opts.author, "鲁迅")
    Assert.is_false(FakeBooks.list_opts.unauthor)
    Assert.eq(FakeBooks.list_opts.chapter_sources[1], "wechat", "每行都要算 downloaded，章节源总是传")
    Assert.eq(seen_scope, "local")

    Catalog.listLibraryAsync("local", { downloaded = true }, function() end)
    Stubs.flush()
    Assert.is_true(FakeBooks.list_opts.downloaded)
    Assert.eq(#FakeBooks.list_opts.chapter_sources, 1)
    Assert.eq(FakeBooks.list_opts.chapter_sources[1], "wechat")
end

do -- filtersAsync
    FakeBooks.category_counts = { { category = "科幻", count = 2 } }
    FakeBooks.series_counts = { { series = "三体", count = 2 } }
    FakeBooks.authors_counts = { { authors = "刘慈欣", count = 3 } }
    FakeBooks.read_counts = { { status = "read", count = 1 } }
    local got
    Catalog.filtersAsync("local", function(res)
        got = res
    end)
    Stubs.flush()
    Assert.eq(got.data.category_counts[1].count, 2)
    Assert.eq(got.data.series_counts[1].series, "三体")
    Assert.eq(got.data.author_counts[1].authors, "刘慈欣")
    Assert.eq(got.data.read_counts[1].status, "read")
    Assert.eq(got.data.downloaded_count, 3)
    Assert.eq(got.data.hidden_count, 2)
    Assert.eq(FakeBooks.count_chapter_sources[1], "wechat")
    Assert.is_nil(got.data.source_counts)
end

do -- recentBooks：进度定顺序和位置，books 只补元数据；已下载按属主源类型查库
    FakeBooks.recent = {
        { source_id = "local", stable_id = "b.epub", fraction = 0.75,
            chapter_idx = 3, chapter_title = "第三章", updated_at = 200 },
        { source_id = "wechat", stable_id = "w1", fraction = 0.25, updated_at = 100 },
    }
    FakeBooks.meta = {
        ["local\nb.epub"] = { stable_id = "b.epub", title = "B", percent = 1 },
        ["wechat\nw1"] = { stable_id = "w1", title = "W", percent = 99 },
    }
    FakeBooks.downloaded_asks = {}
    local got = Catalog.recentBooks("local", 24)
    Assert.eq(got[1].stable_id, "b.epub")
    Assert.eq(got[1].percent, 75)
    Assert.eq(got[1].chapter_idx, 3)
    Assert.eq(got[1].chapter_title, "第三章")
    Assert.is_true(got[1].downloaded)
    Assert.eq(got[2].stable_id, "w1")
    Assert.is_false(got[2].downloaded)
    Assert.is_false(FakeBooks.downloaded_asks[1][3], "local 是整本源")
    Assert.is_true(FakeBooks.downloaded_asks[2][3], "wechat 是章节源")
end

do -- readingInsightAsync
    FakeStats.summary = { total_seconds = 120, total_pages = 3 }
    FakeStats.daily = { { ymd = "2026-08-21", seconds = 120, pages = 4 }, { ymd = "2026-08-22", seconds = 60 } }
    FakeStats.daily_books = {
        { ymd = "2026-08-21", stable_id = "c.epub", max_page = 2, max_total_pages = 10 },
    }
    local hours = {}
    for h = 1, 24 do hours[h] = h == 22 and 120 or 0 end
    FakeStats.hourly = { ["2026-08-21"] = hours }
    FakeBooks.meta = { ["local\nc.epub"] = { title = "C", authors = "作者" } }
    local got
    Catalog.readingInsightAsync("local", function(res)
        got = res
    end)
    Stubs.flush()
    Assert.is_true(got.data.has_data)
    Assert.eq(got.data.total.total_seconds, 120)
    Assert.eq(got.data.calendar.days["2026-08-21"].pages, 4)
    Assert.eq(got.data.calendar.days["2026-08-21"].hours, hours)
    Assert.is_nil(got.data.calendar.days["2026-08-22"].hours, "只有云端时长的日子没有小时分布")
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
