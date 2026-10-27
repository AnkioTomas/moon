--[[--
京东读书源书城与本地统计能力离线用例。

@module tests.source.jdread_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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
        rememberMany = function(books) remembered = books; return true end,
        markDeleted = function() return true end,
    }
end
package.preload["book.books_db"] = function()
    return {
        reconcile = function(_, books)
            remembered = books
            return true, 0
        end,
        remove = function(_, stable_id)
            finalized[#finalized + 1] = stable_id
            return true
        end,
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
package.loaded["book.books_db"] = nil
package.loaded["source.jdread"] = nil

local Jdread = require("source.jdread")

do
    local source = Jdread.new()
    local caps = source:capabilities()
    Assert.is_false(caps.stats_pull)
    Assert.is_false(type(source.pushStatsAsync) == "function")
end

-- 图书馆列表行不带 cover：基类按身份查书库取 URL；非 http 或缺失给 nil
do
    local source = Jdread.new()
    local stored = {
        ["42"] = { cover = "https://img.jd.com/42.jpg" },
        ["43"] = { cover = "${free_list[i].cover}" },
    }
    local BookDB = require("book.books_db")
    BookDB.get = function(source_id, stable_id)
        Assert.eq(source_id, "jdread")
        return stored[stable_id]
    end
    Assert.eq(source:coverRequest({ stable_id = "42" }).url, "https://img.jd.com/42.jpg")
    Assert.eq(source:coverRequest({ stable_id = "42", cover = "https://x/y.jpg" }).url, "https://x/y.jpg")
    local req, err = source:coverRequest({ stable_id = "43" })
    Assert.is_nil(req)
    Assert.eq(err, "无封面")
    Assert.is_nil((source:coverRequest({ stable_id = "44" })))
    BookDB.get = nil
end

-- syncBooksAsync：本地独有成员上行，pushed 填实
do
    local added, shelf_calls = {}, 0
    local list_calls = 0
    fake_client.shelfSyncAsync = function(_, cb)
        shelf_calls = shelf_calls + 1
        cb({ { ebook_id = 10, name = "远端" } })
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
        return { { stable_id = "10", title = "远端" } }
    end
    -- 10 已在远端：只标已同步不再请求；99 是本地新加架，上行。
    pending_adds = { "10", "99" }
    local synced = {}
    local db = require("book.books_db")
    local orig_mark = db.markSynced
    db.markSynced = function(_, stable_id)
        synced[#synced + 1] = stable_id
        return true
    end
    local src = Jdread.new()
    local result, err
    src:syncBooksAsync(nil, function(r, e) result, err = r, e end)
    require("support.stubs").flush()
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
    require("support.stubs").flush()
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
    require("support.stubs").flush()
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
    local BookDB = require("book.books_db")
    BookDB.remove = function(_, stable_id)
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
    require("support.stubs").flush()
    Assert.eq(result.pushed, 0)
    Assert.eq(#finalized, 1)
    BookDB.remove = function(_, stable_id)
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
    package.loaded["book.books_db"].markSynced = function(_, stable_id)
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
    require("support.stubs").flush()
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
    package.loaded["book.books_db"].markSynced = function() return false end
    fake_client.addToShelfAsync = function(_, _, cb)
        cb({ ok = true })
        return { cancel = function() end }
    end
    local src = Jdread.new()
    local result
    src:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
    require("support.stubs").flush()
    Assert.eq(result.pushed, 0)
    Assert.eq(warnings[1][1], "jdread shelf mark synced failed")
    package.loaded["book.books_db"].markSynced = function() return true end
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
    fake_client.downloadChapterAsync = function(_, _, query, cb)
        Assert.eq(query.indexes, "0")
        cb({ data = { chapter = { { content = "<p>正文</p>" } } } })
        return { cancel = function() end }
    end

    local source = Jd.new()
    source.loadTocAsync = function(_, _, cb)
        cb({
            { idx = 1, uid = "0", title = "第一章", toc_version = 5 },
            { idx = 2, uid = "1", title = "第二章" },
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

-- 失效目录（旧 cread 版本 1）读到即清库重拉；正文按新目录同 idx 的 uid 下载
do
    local Toc = require("source.toc")
    local orig_read, orig_put = Toc.read, Toc.put
    local stored = { { idx = 1, uid = "56958326", title = "第一章", toc_version = 1 } }
    Toc.read = function() return stored end
    Toc.put = function(_, _, list) stored = list; return true end
    local cleared = {}
    package.loaded["book.books_db"].clearToc = function(_, stable_id)
        cleared[#cleared + 1] = stable_id
        stored = nil
        return true
    end
    local catalog_calls = 0
    fake_client.catalogAsync = function(_, _, cb)
        catalog_calls = catalog_calls + 1
        cb({ data = { format = "epub", chapter_info = { { chapter_index = 0, chapter_name = "第一章" } } } })
        return { cancel = function() end }
    end
    local asked
    fake_client.downloadChapterAsync = function(_, _, query, cb)
        asked = query
        cb({ data = { chapter = { { content = "<p>新</p>" } } } })
        return { cancel = function() end }
    end
    local html
    require("source.chapter").prefetchAsync = function(identity, _, toc, _, _, opts, cb)
        opts.fetchContent(identity, toc[1], function(payload) html = payload.html; cb() end)
        return { cancel = function() end }
    end
    local src = Jdread.new()
    local old = stored
    Assert.is_false(src:isTocCurrent(old))
    Assert.is_false(src:isTocCurrent({ { idx = 1, uid = "0", title = "无版本" } }))
    Assert.is_false(src:isTocCurrent({}))
    src:prefetchChaptersAsync(
        { source_id = "jdread", stable_id = "30451107", book = { stable_id = "30451107" } },
        old, 1, 1, function() end
    )
    Assert.eq(cleared[1], "30451107")
    Assert.eq(catalog_calls, 1)
    Assert.eq(asked.indexes, "0")
    Assert.matches(html, "<p>新</p>")
    Assert.eq(stored[1].toc_version, 5)
    Assert.is_true(src:isTocCurrent(stored))
    Assert.is_false(src:isTocCurrent({ { idx = 1, uid = "0", title = "旧 EPUB 目录", toc_version = 2 } }))
    Assert.is_false(src:isTocCurrent({ { idx = 1, uid = "0", title = "无锚点目录", toc_version = 4 } }))

    -- 网页协议判定 can_read=false：提示走 App，不冒充网络/权限错误
    fake_client.downloadChapterAsync = function(_, _, _, cb)
        cb({ data = { content_type = "net", chapter = { { chapter_id = "c37", can_read = false } } } })
        return { cancel = function() end }
    end
    local denied
    require("source.chapter").prefetchAsync = function(identity, _, toc, _, _, opts, cb)
        opts.fetchContent(identity, toc[1], function(_, err) denied = err; cb() end)
        return { cancel = function() end }
    end
    src:prefetchChaptersAsync(
        { source_id = "jdread", stable_id = "30451107", book = { stable_id = "30451107" } },
        stored, 1, 1, function() end
    )
    Assert.eq(denied, "京东读书网页协议读不到本章，请在京东读书 App 内阅读")
    Toc.read, Toc.put = orig_read, orig_put
end

-- getProgressAsync：目录未缓存时拉到目录后仍按章节标题兜底（JD chapter_id 对不上本地 uid）
do
    local Toc = require("source.toc")
    local orig_read, orig_put, orig_index = Toc.read, Toc.put, Toc.index
    local stored
    Toc.read = function() return stored end
    Toc.put = function(_, _, list) stored = list; return true end
    Toc.index = function() return nil end
    fake_client.getProgressAsync = function(_, _, cb)
        cb({ data = { { list = { {
            data_type = 0, version = 2, percent = 0.4,
            epub_chapter_title = "第二章", chapter_id = "jd-998",
        } } } } })
        return { cancel = function() end }
    end
    fake_client.catalogAsync = function(_, _, cb)
        cb({ data = { format = "epub", chapter_info = {
            { chapter_index = 0, chapter_name = "第一章" },
            { chapter_index = 1, chapter_name = "第二章" },
        } } })
        return { cancel = function() end }
    end
    local pos
    Jdread.new():getProgressAsync({ source_id = "jdread", stable_id = "30451107" }, function(v) pos = v end)
    require("support.stubs").flush()
    Assert.eq(pos.chapter_idx, 2)
    Assert.eq(pos.extra.chapter_idx, 2)

    -- 目录已缓存但 uid、标题都对不上：只定位一次，不再空转拉目录
    stored = { { idx = 1, uid = "0", title = "第一章", toc_version = 5 } }
    local catalog_calls = 0
    fake_client.catalogAsync = function(_, _, cb)
        catalog_calls = catalog_calls + 1
        cb(nil, "should not fetch")
        return { cancel = function() end }
    end
    pos = nil
    Jdread.new():getProgressAsync({ source_id = "jdread", stable_id = "30451107" }, function(v) pos = v end)
    require("support.stubs").flush()
    Assert.eq(catalog_calls, 0)
    Assert.eq(pos.fraction, 0.4)
    Assert.is_nil(pos.chapter_idx)
    Toc.read, Toc.put, Toc.index = orig_read, orig_put, orig_index
end

-- putProgressAsync：章节 uid 取自目录；缺章节号直接失败，不把进度推到第 1 章
do
    local Toc = require("source.toc")
    local orig_read = Toc.read
    Toc.read = function()
        return {
            { idx = 1, uid = "0", title = "第一章", toc_version = 5 },
            { idx = 2, uid = "1", title = "第二章" },
        }
    end
    local marker
    fake_client.putProgressAsync = function(_, _, m, cb)
        marker = m
        cb({ result_code = 0 })
        return { cancel = function() end }
    end
    local src = Jdread.new()
    local identity = { source_id = "jdread", stable_id = "30451107" }
    local ok, err
    src:putProgressAsync(identity, { fraction = 0.5, chapter_idx = 2 }, function(v, e) ok, err = v, e end)
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(marker.chapter_id, "1")
    Assert.eq(marker.epub_chapter_title, "第二章")
    Assert.eq(marker.percent, 0.5)

    marker, ok, err = nil, nil, nil
    src:putProgressAsync(identity, { fraction = 0.5 }, function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "缺少章节信息")
    Assert.is_nil(marker)

    src:putProgressAsync(identity, { fraction = 0.5, chapter_idx = 9 }, function(v, e) ok, err = v, e end)
    Assert.eq(err, "缺少章节信息")
    Assert.is_nil(marker)
    Toc.read = orig_read
end

-- 封面章：网页版只给空 body，用目录首章挂的封面图补成一页
do
    local Toc = require("source.toc")
    local orig_read = Toc.read
    Toc.read = function()
        return { { idx = 1, uid = "0", title = "封面", toc_version = 5, cover = "https://img.test/c.jpg" } }
    end
    fake_client.downloadChapterAsync = function(_, _, _, cb)
        cb({ data = { content_type = "epub", chapter = { {
            content = '<?xml version="1.0"?><html><head><title>Cover</title></head><body></body></html>',
        } } } })
        return { cancel = function() end }
    end
    local html
    require("source.chapter").prefetchAsync = function(identity, _, toc, _, _, opts, cb)
        opts.fetchContent(identity, toc[1], function(payload) html = payload.html; cb() end)
        return { cancel = function() end }
    end
    require("source.assets").localizeAsync = function(raw, _, _, done) done(raw) end
    Jdread.new():prefetchChaptersAsync(
        { source_id = "jdread", stable_id = "30982479", book = { stable_id = "30982479" } },
        { { idx = 1, uid = "0", title = "封面" } }, 1, 1, function() end
    )
    Assert.eq(html, '<p><img src="https://img.test/c.jpg"/></p>')
    Toc.read = orig_read
end

-- 开书迁移：旧版目录（版本 2）章数和新目录不同，章节文件章号错位，清整本缓存后再开；
-- 章数相同保留缓存；目录已是新版不发请求
do
    local Toc = require("source.toc")
    local orig_read, orig_put = Toc.read, Toc.put
    local Chapter = require("source.chapter")
    local orig_open = Chapter.openWithUi
    local old
    Toc.read = function() return old end
    Toc.put = function() return true end
    local cleared, catalog_calls, opened = {}, 0, 0
    require("book.store").clearCache = function(_, stable_id)
        cleared[#cleared + 1] = stable_id
        return true
    end
    fake_client.catalogAsync = function(_, _, cb)
        catalog_calls = catalog_calls + 1
        cb({ data = { format = "epub", chapter_info = {
            { chapter_index = 0, chapter_name = "封面", chapter_uri = "Text/titlepage.xhtml", is_try = true, is_buy = true },
            { chapter_index = 1, chapter_name = "三盏灯", chapter_uri = "Text/a-CD.html", is_try = false, is_buy = true },
            { chapter_index = 2, chapter_name = "1", chapter_uri = "Text/a.html#id_1", anchor = "id_1",
                is_try = true, is_buy = true },
        } } })
        return { cancel = function() end }
    end
    Chapter.openWithUi = function()
        opened = opened + 1
        return { cancel = function() end }
    end
    local identity = { source_id = "jdread", stable_id = "30982479" }
    local src = Jdread.new()

    old = {
        { idx = 1, uid = "0", title = "封面", toc_version = 2 },
        { idx = 2, uid = "1", title = "三盏灯" },
        { idx = 3, uid = "2", title = "1" },
    }
    src:openBookAsync(identity, nil, function() end)
    Assert.eq(catalog_calls, 1)
    Assert.eq(table.concat(cleared, ","), "30982479")
    Assert.eq(opened, 1)

    old = { { idx = 1, uid = "0", title = "封面", toc_version = 2 }, { idx = 2, uid = "1", title = "三盏灯" } }
    src:openBookAsync(identity, nil, function() end)
    Assert.eq(catalog_calls, 2)
    Assert.len(cleared, 1)
    Assert.eq(opened, 2)

    -- v4 已按文件成章、只缺锚点：重拉补小节，章号不变，缓存照用
    old = { { idx = 1, uid = "0", title = "封面", toc_version = 4 }, { idx = 2, uid = "1", title = "三盏灯" } }
    src:openBookAsync(identity, nil, function() end)
    Assert.eq(catalog_calls, 3)
    Assert.len(cleared, 1)
    Assert.eq(opened, 3)

    old = { { idx = 1, uid = "0", title = "封面", toc_version = 5 }, { idx = 2, uid = "1", title = "三盏灯" } }
    src:openBookAsync(identity, nil, function() end)
    Assert.eq(catalog_calls, 3)
    Assert.len(cleared, 1)
    Assert.eq(opened, 4)

    Toc.read, Toc.put, Chapter.openWithUi = orig_read, orig_put, orig_open
end

-- 书城浏览：榜单类别 / 榜单 / 周期 / 分类四行 chip，菜单每次现取（缓存归数据获取层）
do
    local calls, types_calls = {}, 0
    fake_client.rankTypesAsync = function(_, cb)
        types_calls = types_calls + 1
        cb({ data = {
            { name = "出版", type = 1, kinds = {
                { name = "畅销榜", kind = 1, periods = { { name = "周榜", period = "week" }, { name = "总榜", period = "all" } } },
                { name = "飙升榜", kind = 6, periods = { { name = "周榜", period = "week" } } },
            } },
            { name = "男生", type = 2, kinds = { { name = "人气榜", kind = 13, periods = { { name = "周榜", period = "week" } } } } },
        } })
        return { cancel = function() end }
    end
    fake_client.categoriesAsync = function(_, cb)
        cb({ data = { category_list = {
            { show_name = "出版", sub_category = { { id = 10846, name = "经济管理" } } },
            { show_name = "男生", sub_category = { { id = 10944, name = "玄幻频道" } } },
        } } })
        return { cancel = function() end }
    end
    fake_client.rankAsync = function(_, kind, period, cat, page, size, cb)
        calls[#calls + 1] = table.concat({ kind, period, cat, page, size }, ",")
        cb({ data = { { ebook_id = 1, name = "书" } } })
        return { cancel = function() end }
    end

    local src = Jdread.new()
    local res
    local handle = src:browseAsync({}, function(r) res = r end)
    Assert.eq(type(handle.cancel), "function")
    Assert.eq(calls[1], "1,week,,1,20")
    Assert.len(res.data, 1)
    Assert.len(res.groups, 4)
    Assert.eq(res.groups[2].active, "1:1:week:")
    Assert.eq(res.groups[1].active, "1:1:week:")

    src:browseAsync({ node = "1:1:all:10846" }, function(r) res = r end)
    Assert.eq(calls[#calls], "1,all,10846,1,20")
    Assert.eq(res.groups[4].active, "1:1:all:10846")

    -- 切到只有一个周期的男生榜：周期行不出现，分类换成男生的
    src:browseAsync({ node = "2:13:week:10944" }, function(r) res = r end)
    Assert.len(res.groups, 3)
    Assert.eq(res.groups[3].chips[2].title, "玄幻频道")
    Assert.eq(types_calls, 3, "源不留菜单缓存，每次浏览都现取")

    -- 再次切榜单：返回的句柄仍能取消当前在途请求（菜单两个请求先行、同步回完才发榜单请求）。
    local cancelled = 0
    fake_client.rankAsync = function()
        return { cancel = function() cancelled = cancelled + 1 end }
    end
    for _, node in ipairs({ "1:1:all:10846", "2:13:week:10944" }) do
        handle = src:browseAsync({ node = node }, function() error("请求尚未完成") end)
        Assert.eq(type(handle.cancel), "function")
        handle:cancel()
    end
    Assert.eq(cancelled, 2)
    Assert.eq(types_calls, 5)
end

-- 书城搜索：product_search_infos 映射成 Book，源因此出现在书城来源下拉里
do
    fake_client.searchAsync = function(_, keyword, page, size, cb)
        Assert.eq(keyword .. page .. size, "斗120")
        cb({ data = { product_search_infos = { { product_id = 7, product_name = "斗破", author = "土豆", content_info = "简介" } } } })
        return { cancel = function() end }
    end
    local res
    Jdread.new():searchAsync("斗", function(r) res = r end)
    Assert.eq(res.data[1].stable_id, "7")
    Assert.eq(res.data[1].title, "斗破")
    Assert.eq(res.data[1].intro, "简介")
end
