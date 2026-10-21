--[[--
desktop.detail.scrape.search 离线用例：假 douban / novel，测按来源分派与 cancel 语义

@module tests.desktop.detail.scrape.search_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch

local Assert = require("support.assert")

local calls = {}
local pending
package.preload["desktop.detail.scrape.douban"] = function()
    return { searchAsync = function(q, cb)
        calls[#calls + 1] = "douban:" .. q
        pending = cb
        return { cancel = function() calls.cancelled = true end }
    end }
end
package.preload["desktop.detail.scrape.novel"] = function()
    return { viaSource = function(id, q, cb, label)
        calls[#calls + 1] = id .. ":" .. q .. ":" .. tostring(label)
        pending = cb
        return { cancel = function() end }
    end }
end
for _, name in ipairs({ "desktop.detail.scrape.douban", "desktop.detail.scrape.novel", "desktop.detail.scrape.search" }) do
    package.loaded[name] = nil
end
local Search = require("desktop.detail.scrape.search")

local function recorder()
    local r = { n = 0 }
    return r, function(results, err, source)
        r.n, r.results, r.err, r.source = r.n + 1, results, err, source
    end
end

-- 空关键词、未知来源直接拒绝，不触发任何源
do
    local rec, cb = recorder()
    Assert.is_nil(Search.searchAsync("  ", "douban", cb))
    Assert.eq(rec.err, "搜索关键词为空")
    Assert.is_nil(Search.searchAsync("活着", "nope", cb))
    Assert.eq(rec.err, "未知数据源")
    Assert.len(calls, 0)
end

-- 只查选中的来源；成功带回来源 id
do
    local rec, cb = recorder()
    local job = Search.searchAsync(" 活着 ", "douban", cb)
    Assert.eq(calls[1], "douban:活着")
    local rows = { { title = "活着" } }
    pending(rows, nil)
    Assert.eq(rec.results, rows)
    Assert.eq(rec.source, "douban")
    job.cancel()
    Assert.is_true(calls.cancelled)
end

-- 微信读书经 wechat 数据源，结果来源标记 weread；空结果 / 报错都是错误
do
    local rec, cb = recorder()
    Search.searchAsync("活着", "weread", cb)
    Assert.eq(calls[2], "wechat:活着:weread")
    pending({}, nil)
    Assert.eq(rec.err, "无搜索结果")
    Assert.is_nil(rec.source)
    Search.searchAsync("活着", "weread", cb)
    pending(nil, "挂了")
    Assert.eq(rec.err, "挂了")
end

for _, name in ipairs({ "desktop.detail.scrape.douban", "desktop.detail.scrape.novel", "desktop.detail.scrape.search" }) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
