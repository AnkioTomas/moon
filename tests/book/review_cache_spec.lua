--[[--
book.review_cache：在线取最新、离线读缓存、未命中且未联网立即失败、空结果移除热点、过期重拉；
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
        exec = function(sql, source_id, stable_id, idx, kind, key, payload, expire)
            if sql:find("DELETE", 1, true) then
                for row_key, row in pairs(rows) do
                    if row[2] <= source_id then rows[row_key] = nil end
                end
                return true
            end
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
    Assert.len(got, 0, "离线只留首页评论已缓存的句子")
    Assert.eq(ReviewCache.hotspots(ident)[1].total, 5)

    connected = true
    ReviewCache.pageAsync(ident, "1-2", 0, fetcher({ items = { { id = "1" } }, max_idx = 1 }).fetch, function() end)
    connected, got = false, nil
    ReviewCache.hotspotsAsync(ident, f.fetch, function(v) got = v end)
    Stubs.flush()
    Assert.eq(got[1].range, "1-2")

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
    -- 在线忽略已有热点 / 评论页缓存，成功覆盖；失败不能伪装成旧数据或空结果。
    connected = true
    local ci = { source_id = "wechat", stable_id = "fresh", chapter_idx = 23 }
    ReviewCache.hotspotsAsync(ci, fetcher({ { range = "old", total = 5 } }).fetch, function() end)
    local hot = fetcher({ { range = "new", total = 2 } })
    local got, got_err
    ReviewCache.hotspotsAsync(ci, hot.fetch, function(v) got = v end)
    Assert.eq(hot.calls, 1)
    Assert.eq(got[1].range, "new")
    Assert.eq(ReviewCache.hotspots(ci)[1].range, "new")

    local first = fetcher({ items = { { id = "old" } }, total = 1, max_idx = 1, more = false })
    ReviewCache.pageAsync(ci, "new", 0, first.fetch, function() end)
    local fresh = fetcher({ items = { { id = "new" } }, total = 1, max_idx = 1, more = false })
    ReviewCache.pageAsync(ci, "new", 0, fresh.fetch, function(v) got = v end)
    Assert.eq(fresh.calls, 1)
    Assert.eq(got.items[1].id, "new")

    local failed = fetcher(nil, "timeout")
    ReviewCache.pageAsync(ci, "new", 0, failed.fetch, function(v, e) got, got_err = v, e end)
    Assert.is_nil(got)
    Assert.eq(got_err, "timeout")
    Assert.eq(ReviewCache.page(ci, "new", 0).items[1].id, "new", "失败不破坏离线缓存")
    ReviewCache.hotspotsAsync(ci, failed.fetch, function(v, e) got, got_err = v, e end)
    Assert.is_nil(got)
    Assert.eq(got_err, "timeout")
    Assert.eq(ReviewCache.hotspots(ci)[1].range, "new")

    connected = false
    ReviewCache.pageAsync(ci, "new", 0, fresh.fetch, function(v) got = v end)
    Stubs.flush()
    Assert.eq(fresh.calls, 1)
    Assert.eq(got.items[1].id, "new", "离线仍可读最新落库内容")
end

do
    connected = true
    local ci = { source_id = "wechat", stable_id = "empty-hotspot", chapter_idx = 23 }
    local hot = { { range = "gone", total = 3 }, { range = "keep", total = 2 } }
    ReviewCache.hotspotsAsync(ci, fetcher(hot).fetch, function() end)
    local empty = fetcher({ items = {}, total = 0, max_idx = 0, more = false })
    ReviewCache.pageAsync(ci, "gone", 30, empty.fetch, function() end)
    Assert.len(ReviewCache.hotspots(ci), 2, "后续页为空不删除热点")
    ReviewCache.pageAsync(ci, "gone", 0, empty.fetch, function() end)
    Assert.len(ReviewCache.hotspots(ci), 1, "首页总数为零移除旧热点")
    Assert.eq(ReviewCache.hotspots(ci)[1].range, "keep")

    -- 兼容已有的空首页缓存：离线不画点开后没有内容的标记。
    ReviewCache.hotspotsAsync(ci, fetcher(hot).fetch, function() end)
    ReviewCache.pageAsync(ci, "keep", 0,
        fetcher({ items = { { id = "kept" } }, total = 2, max_idx = 1 }).fetch, function() end)
    connected = false
    local got
    ReviewCache.hotspotsAsync(ci, fetcher(nil, "offline").fetch, function(v) got = v end)
    Stubs.flush()
    Assert.len(got, 1)
    Assert.eq(got[1].range, "keep")
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
                local items = {}
                for i = 1, 30 do items[i] = { id = tostring(i) } end
                done({ items = items, total = 99, max_idx = max_idx + 1, more = true })
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
    -- 全本：80 章 × 12 句，每句只拉首页并只存前 10 条。
    rows = {}
    connected = true
    local src = fakeSource()
    local ok, done_n, total_n
    Prefetch.run(src, { source_id = "wechat", stable_id = "cap" }, nil, nil, function(o, n, t)
        ok, done_n, total_n = o, n, t
    end)
    drain()
    Assert.is_true(ok)
    Assert.eq(total_n, 80)
    Assert.eq(src.hot, 80)
    Assert.eq(src.pages, 80 * 12)
    local cached = ReviewCache.page({ source_id = "wechat", stable_id = "cap", chapter_idx = 5 }, "r3", 0)
    Assert.len(cached.items, 10)
    Assert.is_true(cached.partial)
    Assert.is_false(cached.more)

    -- 离线读到 10 条；联网读到 partial 当没有，重拉完整页。
    local pager = fetcher({ items = { { id = "a" }, { id = "b" } }, total = 2, max_idx = 2, more = false })
    local got
    local ci = { source_id = "wechat", stable_id = "cap", chapter_idx = 5 }
    connected = false
    ReviewCache.pageAsync(ci, "r3", 0, pager.fetch, function(v) got = v end)
    Stubs.flush()
    Assert.len(got.items, 10)
    Assert.eq(pager.calls, 0)
    connected = true
    ReviewCache.pageAsync(ci, "r3", 0, pager.fetch, function(v) got = v end)
    Assert.eq(pager.calls, 1)
    Assert.len(got.items, 2)

    -- 再跑一遍：全部命中缓存，不发请求。
    local again = fakeSource()
    Prefetch.run(again, { source_id = "wechat", stable_id = "cap" }, nil, nil, function() end)
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
