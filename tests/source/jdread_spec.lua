--[[--
京东读书源书城与本地统计能力离线用例。

@module tests.source.jdread_spec
--]]

local Assert = require("support.assert")

local fake_client = {
    configured = function() return true end,
}
package.preload["source.jdread.client"] = function()
    return {
        new = function() return fake_client end,
    }
end
package.preload["utils.settings"] = function()
    return {
        getSource = function() return {} end,
    }
end

local remembered
package.preload["book.store"] = function()
    return {
        reconcile = function(_, books)
            remembered = books
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0 }
        end,
        rememberMany = function(books) remembered = books; return true end,
    }
end

package.loaded["source.jdread.client"] = nil
package.loaded["utils.settings"] = nil
package.loaded["book.store"] = nil
package.loaded["source.jdread"] = nil

local Jdread = require("source.jdread")

do
    local source = Jdread.new()
    local caps = source:capabilities()
    Assert.is_true(caps.store)
    Assert.is_true(caps.insight)
    Assert.is_false(caps.stats_pull)
    Assert.is_false(type(source.pushStatsAsync) == "function")
end

do
    local source = Jdread.new()
    source._covers["42"] = "http://img10.360buyimg.com/n12/cover.jpg"
    local request = source:coverRequest({ stable_id = "42" })
    Assert.eq(request.url, "http://img10.360buyimg.com/n12/cover.jpg")
    Assert.is_nil(request.headers)

    local invalid, err = source:coverRequest({
        stable_id = "43",
        book = { cover = "file:///tmp/cover.jpg" },
    })
    Assert.is_nil(invalid)
    Assert.eq(err, "无封面")
end

do
    local called
    fake_client.searchAsync = function(_, keyword, page, page_size, cb)
        called = { keyword = keyword, page = page, page_size = page_size }
        cb({
            data = {
                total_count = 1,
                product_search_infos = {
                    { product_id = 7, product_name = "搜索书" },
                },
            },
        })
        return { cancel = function() end }
    end
    local source = Jdread.new()
    local result
    source:listStoreAsync({ search = "Lua", page = 2, page_size = 30 }, function(value)
        result = value
    end)
    Assert.eq(called.keyword, "Lua")
    Assert.eq(called.page, 2)
    Assert.eq(called.page_size, 30)
    Assert.eq(result.data[1].stable_id, "7")
end

do
    fake_client.shelfSyncAsync = function(_, cb)
        cb({ data = { books = {
            { ebook_id = 8, name = "书架种子一" },
            { ebook_id = 10, name = "书架种子二" },
        } } })
        return { cancel = function() end }
    end
    local seeds = {}
    fake_client.recommendAsync = function(_, book_id, cb)
        seeds[#seeds + 1] = book_id
        if book_id == "8" then
            cb({ data = {
                { ebook_id = 9, name = "推荐书一" },
                { ebook_id = 11, name = "共同推荐" },
            } })
        else
            cb({ data = {
                { ebook_id = 11, name = "共同推荐" },
                { ebook_id = 12, name = "推荐书二" },
            } })
        end
        return { cancel = function() end }
    end
    local source = Jdread.new()
    local result
    source:listStoreAsync({}, function(value) result = value end)
    Assert.eq(seeds[1], "8")
    Assert.eq(seeds[2], "10")
    Assert.len(result.data, 3)
    Assert.eq(result.data[1].stable_id, "9")
    Assert.eq(result.data[2].stable_id, "11")
    Assert.eq(result.data[3].stable_id, "12")
end

do
    local added
    fake_client.addToShelfAsync = function(_, book_id, cb)
        added = book_id
        cb({ result_code = 0 })
        return { cancel = function() end }
    end
    fake_client.shelfSyncAsync = function(_, cb)
        cb({ data = { books = { { ebook_id = 10, name = "已入架" } } } })
        return { cancel = function() end }
    end
    local source = Jdread.new()
    local ok, err, title
    source:addStoreBookAsync({ stable_id = "10", title = "测试书" }, function(value, e, t)
        ok, err, title = value, e, t
    end)
    Assert.eq(added, "10")
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(title, "测试书")
    Assert.eq(remembered[1].stable_id, "10")
end

do
    local prefetch_opts
    package.preload["source.chapter"] = function()
        return {
            prefetchAsync = function(identity, _, toc, from_idx, count, opts, cb)
                prefetch_opts = opts
                Assert.eq(from_idx, 0)
                Assert.eq(count, #toc)
                opts.progress(1, #toc)
                opts.fetchContent(identity, toc[1], function(payload)
                    Assert.matches(payload.html, "正文")
                    cb(2, 2, 0)
                end)
                return { cancel = function() end }
            end,
        }
    end
    package.loaded["source.chapter"] = nil
    fake_client.chapterContentAsync = function(_, _, _, cb)
        cb({ contentList = { { content = "<p>正文</p>" } } })
        return { cancel = function() end }
    end

    local source = Jdread.new()
    source.loadTocAsync = function(_, _, cb)
        cb({
            { idx = 1, uid = "c1", title = "第一章" },
            { idx = 2, uid = "c2", title = "第二章" },
        })
        return { cancel = function() end }
    end
    local progressed, ok, cached, total, failed
    source:cacheAllChaptersAsync(
        { source_id = "jdread", stable_id = "10", book = { stable_id = "10" } },
        function(done, count) progressed = { done, count } end,
        function(success, count, _, all, failures)
            ok, cached, total, failed = success, count, all, failures
        end
    )
    Assert.eq(progressed[1], 1)
    Assert.eq(progressed[2], 2)
    Assert.is_false(prefetch_opts.persist_toc)
    Assert.is_false(prefetch_opts.persist_book)
    Assert.eq(prefetch_opts.interval_seconds, 1.5)
    Assert.is_true(ok)
    Assert.eq(cached, 2)
    Assert.eq(total, 2)
    Assert.eq(failed, 0)
end
