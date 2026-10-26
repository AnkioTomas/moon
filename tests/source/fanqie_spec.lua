--[[--
source.fanqie 门面离线用例。

@module tests.source.fanqie_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

local queue = {}
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, f) queue[#queue + 1] = f end,
    }
end
local function drain()
    while #queue > 0 do table.remove(queue, 1)() end
end

package.loaded["source.base"] = nil
local progress_wire = { data = {} }
local put_args, put_wire = nil, { code = 0 }
local shelf_actions, pending_adds = {}, {}
local search_wire = { code = 0, data = { ret_data = {
    { book_id = "111", title = "搜到的书", author = "某人", abstract = "简介", category = "玄幻",
      thumb_url = "https://p6-tt.bytecdn.cn/novel-pic/abc~tplv-shrink:640:0.image" },
    { title = "没有书号" },
} } }
package.preload["source.fanqie.settings"] = function()
    return {
        new = function()
            return {
                is_cookie_configured = function() return true end,
            }
        end,
    }
end
package.preload["source.fanqie.client"] = function()
    return {
        new = function()
            return {
                fetchShelfDetailAsync = function(_, _force, cb)
                    require("ui/uimanager"):nextTick(function()
                        cb({
                            data = {
                                detail_list = {
                                    {
                                        book_id = "1234567890123456789",
                                        book_name = "测试",
                                        author_name = "作者",
                                        thumb_url = "https://p6-novel.byteimg.com/novel-pic/x~tplv-shrink:320:0.image",
                                        abstract = "简介",
                                    },
                                },
                            },
                        })
                    end)
                    return { cancel = function() end }
                end,
                fetchChapterDirectoryAsync = function(_, _id, cb)
                    require("ui/uimanager"):nextTick(function()
                        cb({
                            data = {
                                chapterList = {
                                    { itemId = "9876543210987654321", title = "第一章" },
                                },
                            },
                        })
                    end)
                    return { cancel = function() end }
                end,
                officialGetContentAsync = function(_, _bid, _iid, cb)
                    require("ui/uimanager"):nextTick(function()
                        cb({ title = "第一章", content = "<p>测试正文</p>" })
                    end)
                    return { cancel = function() end }
                end,
                shelfActionAsync = function(_, action, book_id, cb)
                    shelf_actions[#shelf_actions + 1] = action .. ":" .. book_id
                    require("ui/uimanager"):nextTick(function() cb({ code = 0 }) end)
                    return { cancel = function() end }
                end,
                searchAsync = function(_, _keyword, cb)
                    require("ui/uimanager"):nextTick(function() cb(search_wire) end)
                    return { cancel = function() end }
                end,
                fetchReadProgressAsync = function(_, cb)
                    require("ui/uimanager"):nextTick(function()
                        cb(progress_wire)
                    end)
                    return { cancel = function() end }
                end,
                updateReadProgressAsync = function(_, book_id, item_id, index, progress, cb)
                    put_args = { book_id = book_id, item_id = item_id, index = index, progress = progress }
                    require("ui/uimanager"):nextTick(function()
                        cb(put_wire)
                    end)
                    return { cancel = function() end }
                end,
            }
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end
package.preload["utils.paths"] = function()
    return {
        imageDir = function() return "missing" end,
        coverPath = function() return "missing/cover.jpg" end,
        ensureLayout = function() end,
        bookWorkDir = function() return "work" end,
        ensureBookWork = function() end,
    }
end

local stored
package.preload["book.books_db"] = function()
    return {
        reconcile = function(id, books)
            Assert.eq(id, "fanqie")
            stored = books
            return true, 0
        end,
        pendingDeleteIds = function() return {} end,
        pendingShelfAddIds = function() return pending_adds end,
        markSynced = function() return true end,
        get = function(_source_id, stable_id)
            return stored and stored[1] and stored[1].stable_id == stable_id and stored[1] or nil
        end,
    }
end

local toc
local toc_writable = true
package.preload["source.toc"] = function()
    return {
        read = function() return toc end,
        index = function(_source_id, _stable_id, uid)
            for _idx, ch in ipairs(toc or {}) do
                if ch.uid == uid then return ch.idx end
            end
        end,
        put = function(_, _, v)
            if not toc_writable then return false end
            toc = v
            return true
        end,
    }
end
package.preload["source.chapter"] = function()
    return {
        openAsync = function(_, id, book, opts, ops, cb)
            ops.loadToc(id, function(chapters)
                Assert.eq(chapters[1].uid, "9876543210987654321")
                cb("ready.html")
            end)
        end,
        openWithUi = function()
            error("chapter transition must not open a progress dialog")
        end,
        prefetchAsync = function(_, _, _, _, count, ops, cb)
            Assert.eq(count, 3)
            Assert.eq(ops.interval_seconds, 6)
            cb()
        end,
        cacheAllAsync = function(source, identity, fetchContent, on_progress, cb, interval)
            Assert.eq(source.id, "fanqie")
            Assert.eq(interval, 6)
            on_progress(1, 1)
            fetchContent(identity, { idx = 1, uid = "9876543210987654321", title = "第一章" }, function(payload)
                Assert.eq(payload.html, "<p>测试正文</p>")
                cb(true, 1, nil, 1, 0)
            end)
            return { cancel = function() end }
        end,
    }
end

package.loaded["source.fanqie"] = nil
local src = require("source.fanqie").new()
local settings = src.settings
Assert.is_true(src:configured())
Assert.eq(src.settings, settings)

local count = 0
src:syncBooksAsync({}, function(r, e)
    Assert.not_nil(r)
    Assert.is_nil(e)
    count = r.pulled
end)
drain()
Assert.eq(count, 1)
Assert.eq(stored[1].stable_id, "1234567890123456789")
Assert.eq(stored[1].authors, "作者")
Assert.eq(stored[1].title, "测试")
Assert.matches(stored[1].cover, "p6%-novel%.byteimg%.com")

local ref = { source_id = "fanqie", stable_id = "1234567890123456789" }
src:openBookAsync(ref, { chapter_idx = 1 }, function(path)
    Assert.eq(path, "ready.html")
    count = count + 1
end)
drain()
Assert.eq(count, 2)

local cancelled = src:syncBooksAsync({}, function()
    error("cancelled callback delivered")
end)
cancelled.cancel()
drain()

src:prefetchChaptersAsync(ref, {}, 1, 3, function()
    count = count + 1
end)
Assert.eq(count, 3)

-- 整本下载：走公共 cacheAllAsync，正文用番茄接口，间隔与预取一致（风控）
do
    local progressed, ok, cached
    src:cacheAllChaptersAsync(ref, function(done, total) progressed = { done, total } end,
        function(success, n) ok, cached = success, n end)
    drain()
    Assert.eq(progressed[1], 1)
    Assert.is_true(ok)
    Assert.eq(cached, 1)
end

do
    toc = nil
    toc_writable = false
    local chapters, err
    src:loadTocAsync(ref, function(value, reason)
        chapters, err = value, reason
    end)
    drain()
    Assert.is_nil(chapters)
    Assert.eq(err, "章节目录保存失败")
    Assert.is_nil(toc)

    toc_writable = true
    src:loadTocAsync(ref, function(value) chapters = value end)
    drain()
    Assert.eq(chapters[1].uid, "9876543210987654321")
    local called = false
    local cached = src:loadTocAsync(ref, function() called = true end)
    cached:cancel()
    drain()
    Assert.is_false(called)
end

do
    local result
    src:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
    Assert.is_nil(result)
    drain()
    Assert.eq(result.pushed, 0)
    Assert.len(shelf_actions, 0)

    -- 本地新加架的书经网页接口上行
    pending_adds = { "555" }
    src:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
    drain()
    Assert.eq(result.pushed, 1)
    Assert.eq(shelf_actions[1], "add:555")
    pending_adds = {}
end

-- 书城搜索：只留有书号的行，封面归一到手机 CDN
do
    local res
    src:searchAsync("关键字", function(r) res = r end)
    drain()
    Assert.len(res.data, 1)
    Assert.eq(res.data[1].stable_id, "111")
    Assert.eq(res.data[1].authors, "某人")
    Assert.eq(res.data[1].category, "玄幻")
    Assert.matches(res.data[1].cover, "p6%-novel%.byteimg%.com")
end

-- 封面走基类：查书库 cover（同步书架时写入的手机 CDN 地址）
Assert.matches(src:coverRequest(ref).url, "p6%-novel%.byteimg%.com")

-- 官方网页进度只有章节；read_progress 不是章内比例。
toc = {
    { idx = 1, uid = "a" }, { idx = 2, uid = "b" }, { idx = 3, uid = "c" }, { idx = 4, uid = "d" },
}
do
    progress_wire = { code = 0, data = {
        { book_id = "other", item_id = "a" },
        { book_id = ref.stable_id, item_id = "c", read_progress = 5000 },
    } }
    local pos, err
    src:getProgressAsync(ref, function(p, e) pos, err = p, e end)
    drain()
    Assert.is_nil(err)
    Assert.eq(pos.chapter_idx, 3)
    Assert.is_nil(pos.chapter_fraction, "不能把章节 order 当成万分比")
    Assert.eq(pos.fraction, 0.5)
    Assert.eq(pos.extra.chapter_uid, "c")

    -- 章节不在目录 / 云端没这本书：空进度，不是错误
    progress_wire.data[2].item_id = "gone"
    local meta
    src:getProgressAsync(ref, function(p, e, m) pos, err, meta = p, e, m end)
    drain()
    Assert.is_nil(pos)
    Assert.is_nil(err)
    Assert.is_true(meta.empty)
    progress_wire = { code = 0, data = {} }
    meta = nil
    src:getProgressAsync(ref, function(p, e, m) pos, err, meta = p, e, m end)
    drain()
    Assert.is_true(meta.empty)
end

-- 进度上传：章节序号 → uid + 0 起 index，不伪造网页不支持的章内位置。
do
    local ok, err
    src:putProgressAsync(ref, { chapter_idx = 2, chapter_fraction = 1.5 }, function(r, e) ok, err = r, e end)
    drain()
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(put_args.book_id, ref.stable_id)
    Assert.eq(put_args.item_id, "b")
    Assert.eq(put_args.index, 1)
    Assert.eq(put_args.progress, 0)

    -- 没有章节位置：不发请求，直接报错
    put_args = nil
    src:putProgressAsync(ref, { fraction = 0.3 }, function(r, e) ok, err = r, e end)
    drain()
    Assert.is_nil(ok)
    Assert.eq(err, "缺少番茄章节位置")
    Assert.is_nil(put_args)

    -- 业务码非 0：上传失败
    put_wire = { code = 1001 }
    src:putProgressAsync(ref, { chapter_idx = 1 }, function(r, e) ok, err = r, e end)
    drain()
    Assert.is_nil(ok)
    Assert.eq(err, "番茄进度上传失败")
end
