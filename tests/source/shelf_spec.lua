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

package.preload["book.books_db"] = nil
package.loaded["book.books_db"] = nil
package.loaded["source.shelf"] = nil
return true
