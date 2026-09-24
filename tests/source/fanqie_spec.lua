--[[--
source.fanqie 门面离线用例。

@module tests.source.fanqie_spec
--]]

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

package.preload["source.base"] = function() return {} end
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
                fetchReadProgressAsync = function(_, cb)
                    require("ui/uimanager"):nextTick(function()
                        cb({ data = {} })
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
    }
end

local stored
package.preload["book.store"] = function()
    return {
        reconcile = function(id, books)
            Assert.eq(id, "fanqie")
            stored = books
            return { pulled = #books }
        end,
    }
end

local toc
local toc_writable = true
package.preload["source.fanqie.toc"] = function()
    return {
        read = function() return toc end,
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
    drain()
    Assert.is_true(result.skipped)
    Assert.eq(result.pushed, 0)
end
