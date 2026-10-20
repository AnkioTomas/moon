--[[--
book.review_cache：命中不看网络、未命中且未联网立即失败、联网请求后落库、空结果短 TTL、过期重拉；
book.review_prefetch：章数 / 句数 / 页数上限、命中跳过、失败即停。

@module tests.book.review_cache_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
package.preload["json"] = function() return require("support.json_stub") end
package.loaded["json"] = nil

-- 内存版 utils.db：只认 review_cache 的两条语句。
local rows = {}
local function rowKey(source_id, stable_id, idx, kind, key)
    return table.concat({ source_id, stable_id, idx, kind, key }, "|")
end
package.preload["utils.db"] = function()
    return {
        schema = function() end,
        moveIdentity = function() return true end,
        removeIdentity = function() return true end,
        exec = function(_sql, source_id, stable_id, idx, kind, key, payload, expire)
            rows[rowKey(source_id, stable_id, idx, kind, key)] = { payload, expire }
            return true
        end,
        rowexec = function(_sql, ...)
            local row = rows[rowKey(...)]
            if row then return row[1], row[2] end
        end,
    }
end
package.loaded["utils.db"] = nil
package.loaded["book.review_cache"] = nil

local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end
package.loaded["ui/network/manager"] = nil

local ReviewCache = require("book.review_cache")
local ident = { source_id = "wechat", stable_id = "b1", chapter_idx = 3 }

local function fetcher(value, err)
    local f = { calls = 0 }
    f.fetch = function(done)
        f.calls = f.calls + 1
        done(value, err)
        return { cancel = function() end }
    end
    return f
end

do
    -- 没缓存且没网：立即失败，不发请求。
    connected = false
    local f, got, got_err = fetcher({ { range = "1-2", total = 5 } })
    ReviewCache.hotspotsAsync(ident, f.fetch, function(v, e) got, got_err = v, e end)
    Stubs.flush()
    Assert.is_nil(got)
    Assert.matches(got_err, "未联网")
    Assert.eq(f.calls, 0)

    -- 联网请求并落库；之后断网也命中。
    connected = true
    ReviewCache.hotspotsAsync(ident, f.fetch, function(v) got = v end)
    Assert.eq(f.calls, 1)
    Assert.len(got, 1)
    connected, got = false, nil
    ReviewCache.hotspotsAsync(ident, f.fetch, function(v) got = v end)
    Stubs.flush()
    Assert.eq(f.calls, 1, "命中不再请求")
    Assert.eq(got[1].range, "1-2")
    Assert.eq(ReviewCache.hotspots(ident)[1].total, 5)

    -- 回调前取消：不回调。
    got = nil
    ReviewCache.hotspotsAsync(ident, f.fetch, function(v) got = v end).cancel()
    Stubs.flush()
    Assert.is_nil(got)

    -- 过期（180 天）重拉。
    connected = true
    local real = os.time
    os.time = function() return real() + 181 * 24 * 3600 end
    Assert.is_nil(ReviewCache.hotspots(ident))
    os.time = real
end

do
    -- 评论页按 range + max_idx 分开存；空结果只存 5 分钟。
    connected = true
    local page = fetcher({ items = { { id = "1" } }, total = 1, max_idx = 7, more = false })
    ReviewCache.pageAsync(ident, "9", 0, page.fetch, function() end)
    Assert.eq(ReviewCache.page(ident, "9", 0).max_idx, 7)
    Assert.is_nil(ReviewCache.page(ident, "9", 7))

    local empty = fetcher({ items = {}, total = 0, max_idx = 0, more = false })
    ReviewCache.pageAsync(ident, "empty", 0, empty.fetch, function() end)
    Assert.is_true(ReviewCache.page(ident, "empty", 0) ~= nil)
    local real = os.time
    os.time = function() return real() + 301 end
    Assert.is_nil(ReviewCache.page(ident, "empty", 0), "空结果过 5 分钟重拉")
    os.time = real
end

package.preload["source.chapter"] = function()
    return { cacheRange = function(toc, range)
        if not range then return 0, #toc end
        return range.chapter_idx - 1, range.count or (#toc - range.chapter_idx + 1)
    end }
end
package.loaded["source.chapter"] = nil
package.loaded["book.review_prefetch"] = nil
local Prefetch = require("book.review_prefetch")

--- 假源：每章 12 个热点；每句翻页总有下一页。记录真实请求。
local function fakeSource(fail_at)
    local src = { hot = 0, pages = 0 }
    src.loadTocAsync = function(_self, _identity, cb)
        local toc = {}
        for i = 1, 80 do toc[i] = { uid = tostring(i) } end
        cb(toc)
        return { cancel = function() end }
    end
    src.paragraphHotspotsAsync = function(_self, ident_, cb)
        return ReviewCache.hotspotsAsync(ident_, function(done)
            src.hot = src.hot + 1
            local list = {}
            for i = 1, 12 do list[i] = { range = "r" .. i, text = "", total = i } end
            done(list)
            return { cancel = function() end }
        end, cb)
    end
    src.paragraphReviewPageAsync = function(_self, ident_, range, max_idx, cb)
        return ReviewCache.pageAsync(ident_, range, max_idx, function(done)
            src.pages = src.pages + 1
            if fail_at and src.pages == fail_at then
                done(nil, "限流")
            else
                done({ items = { { id = "x" } }, total = 99, max_idx = max_idx + 1, more = true })
            end
            return { cancel = function() end }
        end, cb)
    end
    return src
end

-- 停顿直接放行：上千次请求走 Stubs.flush 会触发它的防失控上限。
require("ui/uimanager").scheduleIn = function(_self, _delay, fn) fn() end
local function drain() end

do
    -- 上限：50 章 × 10 句 × 2 页；第 11、12 热的句不拉。
    rows = {}
    connected = true
    local src = fakeSource()
    local ok, done_n, total_n
    Prefetch.run(src, { source_id = "wechat", stable_id = "cap" }, { chapter_idx = 1 }, nil, function(o, n, t)
        ok, done_n, total_n = o, n, t
    end)
    drain()
    Assert.is_true(ok)
    Assert.eq(total_n, 50)
    Assert.eq(src.hot, 50)
    Assert.eq(src.pages, 50 * 10 * 2)

    -- 再跑一遍：全部命中缓存，不发请求。
    local again = fakeSource()
    Prefetch.run(again, { source_id = "wechat", stable_id = "cap" }, { chapter_idx = 1 }, nil, function() end)
    drain()
    Assert.eq(again.hot + again.pages, 0)
end

do
    -- 任何一次失败立即停：后面的章不再请求。
    rows = {}
    local src = fakeSource(3)
    local ok, err
    Prefetch.run(src, { source_id = "wechat", stable_id = "fail" }, { chapter_idx = 1, count = 5 }, nil,
        function(o, _n, _t, e) ok, err = o, e end)
    drain()
    Assert.is_false(ok)
    Assert.eq(err, "限流")
    Assert.eq(src.pages, 3)
    Assert.eq(src.hot, 1)
end

return true
