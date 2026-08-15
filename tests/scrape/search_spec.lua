--[[--
scrape.search 离线用例：假 scrape.douban / scrape.weread，测多源编排与 cancel 语义

@module tests.scrape.search_spec
--]]

local Assert = require("support.assert")

-- ── 假数据源：记录调用，回调挂起由测试手动触发 ─────────
local function makeFake()
    return {
        calls = 0,
        pending = nil,
        cancels = 0,
    }
end

local DoubanFake = makeFake()
local WereadFake = makeFake()

local function installFakes()
    package.preload["scrape.douban"] = function()
        return {
            searchAsync = function(_, cb)
                DoubanFake.calls = DoubanFake.calls + 1
                DoubanFake.pending = cb
                return {
                    cancel = function()
                        DoubanFake.cancels = DoubanFake.cancels + 1
                    end,
                }
            end,
        }
    end
    package.preload["scrape.weread"] = function()
        return {
            searchAsync = function(_, _, cb)
                WereadFake.calls = WereadFake.calls + 1
                WereadFake.pending = cb
                return {
                    cancel = function()
                        WereadFake.cancels = WereadFake.cancels + 1
                    end,
                }
            end,
        }
    end
    for _, name in ipairs({ "scrape.douban", "scrape.weread", "scrape.search" }) do
        package.loaded[name] = nil
    end
end

local function resetFakes()
    DoubanFake.calls, DoubanFake.pending, DoubanFake.cancels = 0, nil, 0
    WereadFake.calls, WereadFake.pending, WereadFake.cancels = 0, nil, 0
end

local function cleanup()
    for _, name in ipairs({ "scrape.douban", "scrape.weread", "scrape.search" }) do
        package.preload[name] = nil
        package.loaded[name] = nil
    end
end

installFakes()
local Search = require("scrape.search")

--- 收集 cb 调用
local function recorder()
    local r = { n = 0 }
    return r, function(results, err, source)
        r.n = r.n + 1
        r.results = results
        r.err = err
        r.source = source
    end
end

-- ── 豆瓣成功：直接回调，不回落 weread ──────────────────
do
    resetFakes()
    local rec, cb = recorder()
    local job = Search.searchAsync("活着", cb)
    Assert.eq(type(job.cancel), "function")
    Assert.eq(DoubanFake.calls, 1)

    local rows = { { title = "活着", source = "douban" } }
    DoubanFake.pending(rows, nil)
    Assert.eq(rec.n, 1)
    Assert.eq(rec.results, rows)
    Assert.is_nil(rec.err)
    Assert.eq(rec.source, "douban")
    Assert.eq(WereadFake.calls, 0)
end

-- ── 豆瓣报错：回落 weread ─────────────────────────────
do
    resetFakes()
    local rec, cb = recorder()
    Search.searchAsync("活着", cb)
    DoubanFake.pending(nil, "网络请求失败 (418)")
    Assert.eq(WereadFake.calls, 1)
    Assert.eq(rec.n, 0)

    local rows = { { title = "活着", source = "weread" } }
    WereadFake.pending(rows, nil)
    Assert.eq(rec.n, 1)
    Assert.eq(rec.results, rows)
    Assert.is_nil(rec.err)
    Assert.eq(rec.source, "weread")
end

-- ── 豆瓣空结果（无错误）：同样回落 weread ──────────────
do
    resetFakes()
    local rec, cb = recorder()
    Search.searchAsync("活着", cb)
    DoubanFake.pending({}, nil)
    Assert.eq(WereadFake.calls, 1)

    local rows = { { title = "x" } }
    WereadFake.pending(rows, nil)
    Assert.eq(rec.n, 1)
    Assert.eq(rec.source, "weread")
end

-- ── 两个源都失败：报错回调，source 为 nil ──────────────
do
    resetFakes()
    local rec, cb = recorder()
    Search.searchAsync("活着", cb)
    DoubanFake.pending(nil, "豆瓣挂了")
    WereadFake.pending(nil, "weread 也挂了")
    Assert.eq(rec.n, 1)
    Assert.is_nil(rec.results)
    Assert.eq(rec.err, "weread 也挂了")
    Assert.is_nil(rec.source)
end

-- ── 两个源都空：兜底错误文案 ───────────────────────────
do
    resetFakes()
    local rec, cb = recorder()
    Search.searchAsync("活着", cb)
    DoubanFake.pending({}, nil)
    WereadFake.pending({}, nil)
    Assert.eq(rec.n, 1)
    Assert.is_nil(rec.results)
    Assert.eq(rec.err, "无搜索结果")
    Assert.is_nil(rec.source)
end

-- ── cancel：阻断豆瓣回调与回落，并取消当前 job ─────────
do
    resetFakes()
    local rec, cb = recorder()
    local job = Search.searchAsync("活着", cb)
    job.cancel()
    Assert.eq(DoubanFake.cancels, 1)

    DoubanFake.pending({ { title = "活着" } }, nil)
    Assert.eq(rec.n, 0)
    Assert.eq(WereadFake.calls, 0)
end

-- ── 回落途中 cancel：取消的是 weread 的 job，回调被吞 ──
do
    resetFakes()
    local rec, cb = recorder()
    local job = Search.searchAsync("活着", cb)
    DoubanFake.pending(nil, "豆瓣挂了")
    Assert.eq(WereadFake.calls, 1)

    job.cancel()
    Assert.eq(WereadFake.cancels, 1)

    WereadFake.pending({ { title = "活着" } }, nil)
    Assert.eq(rec.n, 0)
end

cleanup()
