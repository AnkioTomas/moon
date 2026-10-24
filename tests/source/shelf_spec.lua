--[[--
source.shelf：pushDeletes 串行推删、成功才撕墓碑、回调一律异步、可取消。

@module tests.source.shelf_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

local pending, removed = {}, {}
package.preload["book.books_db"] = function()
    return {
        pendingDeleteIds = function() return pending end,
        remove = function(_source_id, stable_id)
            removed[#removed + 1] = stable_id
            return true
        end,
    }
end
package.loaded["book.books_db"] = nil
package.loaded["source.shelf"] = nil
local Shelf = require("source.shelf")

local function noop() end

-- 无待删：下一帧才回调 0，调用方拿得到句柄
do
    local got
    local handle = Shelf.pushDeletes("x", function() error("不该发请求") end, noop, function(n) got = n end)
    Assert.not_nil(handle)
    Assert.is_nil(got)
    Stubs.flush()
    Assert.eq(got, 0)
end

-- 无待删且已取消：不回调
do
    local got
    Shelf.pushDeletes("x", noop, noop, function(n) got = n end):cancel()
    Stubs.flush()
    Assert.is_nil(got)
end

-- 远端成功才撕墓碑并计数；失败跳过继续下一本；进度按本上报
do
    pending, removed = { "a", "b", "c" }, {}
    local reports, got = {}, nil
    Shelf.pushDeletes("x", function(stable_id, done)
        done(stable_id ~= "b" and { ok = true } or nil)
    end, function(_text, done, total) reports[#reports + 1] = done .. "/" .. total end,
    function(n) got = n end)
    Assert.eq(got, 2)
    Assert.eq(table.concat(removed, ","), "a,c")
    Assert.eq(table.concat(reports, ","), "1/3,2/3,3/3")
end

-- 取消：在飞请求被取消、不再推下一本、不回调；
-- 取消后远端仍确认删了那本，照样撕墓碑（远端已无此书，留着只会下轮重推）
do
    pending, removed = { "a", "b" }, {}
    local inflight, cancelled, requested, got = nil, 0, {}, nil
    local handle = Shelf.pushDeletes("x", function(stable_id, done)
        requested[#requested + 1] = stable_id
        inflight = done
        return { cancel = function() cancelled = cancelled + 1 end }
    end, noop, function(n) got = n end)
    handle:cancel()
    Assert.eq(cancelled, 1)
    inflight({ ok = true })
    Assert.eq(table.concat(removed, ","), "a")
    Assert.eq(table.concat(requested, ","), "a")
    Assert.is_nil(got)
end

-- 同源已有一轮在推（启动 pushDirty 与书架同步并发）：第二轮不重复推同一本，推完才放行
do
    pending, removed = { "a" }, {}
    local requests, first_done, second = 0, nil, nil
    Shelf.pushDeletes("y", function(_stable_id, done)
        requests = requests + 1
        first_done = done
        return { cancel = noop }
    end, noop, noop)
    Shelf.pushDeletes("y", function() error("不该重复推删") end, noop, function(n) second = n end)
    Stubs.flush()
    Assert.eq(second, 0)
    Assert.eq(requests, 1)
    first_done({ ok = true })
    local again = 0
    Shelf.pushDeletes("y", function(_stable_id, done) again = again + 1; done({ ok = true }) end, noop, noop)
    Assert.eq(again, 1)
end

-- 远端书架自带进度：读完必标已读，99% 看设置
do
    local marked = {}
    package.preload["book.books_db"] = function()
        return {
            reconcile = function() return true, 0 end,
            markReadAutomatically = function(_source_id, stable_id) marked[#marked + 1] = stable_id; return true end,
        }
    end
    local reader_conf = { auto_mark_read_at_99 = false }
    package.loaded["utils.settings"] = { get = function() return reader_conf end }
    package.loaded["book.books_db"] = nil
    package.loaded["source.shelf"] = nil
    local S = require("source.shelf")
    local books = {
        { stable_id = "done", percent = 100 }, { stable_id = "near", percent = 99 },
        { stable_id = "mid", percent = 50 }, { stable_id = "none" },
    }
    Assert.not_nil(S.reconcile("x", books))
    Assert.eq(table.concat(marked, ","), "done")
    marked, reader_conf.auto_mark_read_at_99 = {}, true
    S.reconcile("x", books)
    Assert.eq(table.concat(marked, ","), "done,near")
    package.loaded["utils.settings"] = nil
    package.loaded["source.shelf"] = nil
end
package.preload["book.books_db"] = nil
package.loaded["book.books_db"] = nil
package.loaded["source.shelf"] = nil
return true
