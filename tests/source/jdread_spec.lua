--[[--
京东读书源书城与本地统计能力离线用例。

@module tests.source.jdread_spec
--]]

local Assert = require("support.assert")

local warnings = {}
package.preload["utils.log"] = function()
    return {
        warn = function(...)
            warnings[#warnings + 1] = { ... }
        end,
        dbg = function() end,
        info = function() end,
    }
end

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
local local_library = {}
local pending_deletes = {}
local pending_adds = {}
local finalized = {}
package.preload["book.store"] = function()
    return {
        reconcile = function(_, books)
            remembered = books
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0 }
        end,
        rememberMany = function(books) remembered = books; return true end,
        markDeleted = function() return true end,
        finalizeDeleted = function(_, stable_id)
            finalized[#finalized + 1] = stable_id
            return true
        end,
    }
end
package.preload["db.book"] = function()
    return {
        libraryStableIdsBySource = function() return local_library end,
        pendingDeleteIds = function() return pending_deletes end,
        pendingShelfAddIds = function() return pending_adds end,
        markSynced = function() return true end,
        getToc = function() return nil end,
        setToc = function() end,
    }
end

package.loaded["source.jdread.client"] = nil
package.loaded["utils.settings"] = nil
package.loaded["book.store"] = nil
package.loaded["db.book"] = nil
package.loaded["source.jdread"] = nil

local Jdread = require("source.jdread")

do
    local source = Jdread.new()
    local caps = source:capabilities()
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

-- syncBooksAsync：本地独有成员上行，pushed 填实
do
    local added, shelf_calls = {}, 0
    local list_calls = 0
    fake_client.shelfSyncAsync = function(_, cb)
        shelf_calls = shelf_calls + 1
        cb({
            books = {
                { ebook_id = "10", name = "远端" },
            },
        })
        return { cancel = function() end }
    end
    fake_client.addToShelfAsync = function(_, book_id, cb)
        added[#added + 1] = tostring(book_id)
        cb({ ok = true })
        return { cancel = function() end }
    end
    -- 绕过 mapper：直接让 shelfList 返回可控列表
    local real_mapper = require("source.jdread.mapper")
    local orig_shelf = real_mapper.shelfList
    real_mapper.shelfList = function()
        list_calls = list_calls + 1
        return { data = { { stable_id = "10", title = "远端" } } }
    end
    -- 10 已在远端：只标已同步不再请求；99 是本地新加架，上行。
    pending_adds = { "10", "99" }
    local synced = {}
    local db = require("db.book")
    local orig_mark = db.markSynced
    db.markSynced = function(_, stable_id)
        synced[#synced + 1] = stable_id
        return true
    end
    local src = Jdread.new()
    local result, err
    src:syncBooksAsync(nil, function(r, e) result, err = r, e end)
    Assert.is_nil(err)
    Assert.not_nil(result)
    Assert.eq(result.pushed, 1)
    Assert.eq(#added, 1)
    Assert.eq(added[1], "99")
    Assert.eq(table.concat(synced, ","), "10,99")
    Assert.eq(shelf_calls, 2)
    Assert.eq(list_calls, 2)

    -- 已同步的本地书云端已移除：不得加回云端，交给 reconcile 软删。
    added, shelf_calls, list_calls = {}, 0, 0
    pending_adds = {}
    local_library = { "10", "77" }
    remembered = nil
    src:syncBooksAsync(nil, function(r, e) result, err = r, e end)
    Assert.is_nil(err)
    Assert.eq(#added, 0)
    Assert.eq(result.pushed, 0)
    Assert.eq(shelf_calls, 1)
    Assert.eq(#remembered, 1)
    Assert.eq(remembered[1].stable_id, "10")
    real_mapper.shelfList = orig_shelf
    db.markSynced = orig_mark
    local_library = {}
end

-- dirty_only：远端删除失败不撕墓碑，且必须留下日志
do
    warnings = {}
    finalized = {}
    pending_deletes = { "gone" }
    pending_adds = {}
    fake_client.removeFromShelfAsync = function(_, stable_id, cb)
        cb(nil, "network")
        return { cancel = function() end }
    end
    local src = Jdread.new()
    local result, err
    src:syncBooksAsync({ dirty_only = true }, function(r, e) result, err = r, e end)
    Assert.is_nil(err)
    Assert.eq(result.pushed, 0)
    Assert.eq(#finalized, 0)
    Assert.eq(warnings[1][1], "jdread shelf delete push failed")
    Assert.eq(warnings[1][2], "gone")
    pending_deletes = {}
end

-- dirty_only：云端删除成功但本地撕墓碑失败，不得计 pushed
do
    finalized = {}
    pending_deletes = { "gone" }
    pending_adds = {}
    local Store = require("book.store")
    Store.finalizeDeleted = function(_, stable_id)
        finalized[#finalized + 1] = stable_id
        return false
    end
    fake_client.removeFromShelfAsync = function(_, _, cb)
        cb({ ok = true })
        return { cancel = function() end }
    end
    local src = Jdread.new()
    local result
    src:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
    Assert.eq(result.pushed, 0)
    Assert.eq(#finalized, 1)
    Store.finalizeDeleted = function(_, stable_id)
        finalized[#finalized + 1] = stable_id
        return true
    end
    pending_deletes = {}
end

-- dirty_only：加架失败不 markSynced，且必须留下日志
do
    warnings = {}
    pending_deletes = {}
    pending_adds = { "99" }
    local synced = {}
    package.loaded["db.book"].markSynced = function(_, stable_id)
        synced[#synced + 1] = stable_id
        return true
    end
    fake_client.addToShelfAsync = function(_, stable_id, cb)
        cb(nil, "denied")
        return { cancel = function() end }
    end
    local src = Jdread.new()
    local result
    src:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
    Assert.eq(result.pushed, 0)
    Assert.eq(#synced, 0)
    Assert.eq(warnings[1][1], "jdread shelf push failed")
    Assert.eq(warnings[1][2], "99")
    pending_adds = {}
end

-- dirty_only：云端加架成功但本地 markSynced 失败，不得计 pushed
do
    warnings = {}
    pending_deletes = {}
    pending_adds = { "99" }
    package.loaded["db.book"].markSynced = function() return false end
    fake_client.addToShelfAsync = function(_, _, cb)
        cb({ ok = true })
        return { cancel = function() end }
    end
    local src = Jdread.new()
    local result
    src:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
    Assert.eq(result.pushed, 0)
    Assert.eq(warnings[1][1], "jdread shelf mark synced failed")
    package.loaded["db.book"].markSynced = function() return true end
    pending_adds = {}
end

do
    local prefetch_opts
    package.loaded["source.chapter"] = nil
    require("source.chapter").prefetchAsync = function(identity, _, toc, from_idx, count, opts, cb)
        prefetch_opts = opts
        Assert.eq(from_idx, 0)
        Assert.eq(count, #toc)
        opts.progress(1, #toc)
        opts.fetchContent(identity, toc[1], function(payload)
            Assert.matches(payload.html, "正文")
            cb(2, 2, 0)
        end)
        return { cancel = function() end }
    end
    package.loaded["source.jdread"] = nil
    local Jd = require("source.jdread")
    fake_client.chapterContentAsync = function(_, _, _, cb)
        cb({ contentList = { { content = "<p>正文</p>" } } })
        return { cancel = function() end }
    end

    local source = Jd.new()
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

-- 目录版本 3（txt 网文）正文按网页阅读器协议 { type = 1, ids = chapter_id } 下载
do
    local Toc = require("source.toc")
    local orig_read = Toc.read
    Toc.read = function()
        return { { idx = 1, uid = "15001647875062768", title = "第一章", toc_version = 3 } }
    end
    local asked
    fake_client.downloadChapterAsync = function(_, book_id, query, cb)
        asked = { book_id = book_id, query = query }
        cb({ data = { content_type = "net", chapter = {{ content = "　　正文一\r\n正文二" }} } })
        return { cancel = function() end }
    end
    fake_client.chapterContentAsync = function()
        error("txt 网文不应走 cread")
    end
    local html
    require("source.chapter").prefetchAsync = function(identity, _, toc, _, _, opts, cb)
        opts.fetchContent(identity, toc[1], function(payload) html = payload.html; cb() end)
        return { cancel = function() end }
    end
    local src = Jdread.new()
    src:prefetchChaptersAsync(
        { source_id = "jdread", stable_id = "34028897", book = { stable_id = "34028897" } },
        { { idx = 1, uid = "15001647875062768", title = "第一章" } },
        1, 1, function() end
    )
    Assert.eq(asked.book_id, "34028897")
    Assert.eq(asked.query.type, 1)
    Assert.eq(asked.query.ids, "15001647875062768")
    Assert.is_nil(asked.query.indexes)
    Assert.eq(html, "<p>正文一</p>\n<p>正文二</p>")
    Toc.read = orig_read
end
