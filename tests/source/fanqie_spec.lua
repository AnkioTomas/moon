--[[--
source.fanqie 门面离线用例（来自 PR#29，改为 Assert）。

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
                cache_dir = "missing",
                is_cookie_configured = function() return true end,
            }
        end,
    }
end
package.preload["source.fanqie.client"] = function()
    return {
        new = function()
            return {
                fetch_shelf_detail = function()
                    return {
                        data = {
                            detail_list = {
                                {
                                    book_id = "1234567890123456789",
                                    book_name = "测试",
                                    author = "作者",
                                },
                            },
                        },
                    }
                end,
                fetch_chapter_directory = function()
                    return {
                        data = {
                            chapterList = {
                                { itemId = "9876543210987654321", title = "第一章" },
                            },
                        },
                    }
                end,
                official_get_content = function()
                    return { title = "第一章", content = "<p>测试正文</p>" }
                end,
                fetch_read_progress = function()
                    return { data = {} }
                end,
            }
        end,
    }
end
package.preload["workers.job"] = function()
    return {
        run = function(work, opts)
            require("ui/uimanager"):nextTick(function()
                local ok, r = pcall(work)
                if ok then
                    if opts.on_done then opts.on_done(r) end
                else
                    if opts.on_failed then opts.on_failed(r) end
                end
            end)
            return { cancel = function() end }
        end,
    }
end
package.preload["source.fanqie.helper"] = function()
    return { make_dir = function() end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end
package.preload["utils.paths"] = function()
    return {
        imageDir = function() return "missing" end,
        coverPath = function() return "missing/cover.jpg" end,
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
package.preload["source.fanqie.toc"] = function()
    return {
        read = function() return toc end,
        put = function(_, _, v) toc = v end,
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
Assert.is_true(src:configured())

local count = 0
src:syncBooksAsync({}, function(r, e)
    Assert.not_nil(r)
    Assert.is_nil(e)
    count = r.pulled
end)
drain()
Assert.eq(count, 1)
Assert.eq(stored[1].stable_id, "1234567890123456789")

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
    local result
    src:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
    drain()
    Assert.is_true(result.skipped)
    Assert.eq(result.pushed, 0)
end
