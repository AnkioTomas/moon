--[[--
source.kindle：cc.db 快照入书架、打开时直接给文件或子进程转换，路径归属本源。

@module tests.source.kindle_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["utils.log"] = function()
    return { dbg = function() end, info = function() end, warn = function() end }
end

local ticks = {}
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, fn) ticks[#ticks + 1] = fn end }
end
local function flush()
    while #ticks > 0 do table.remove(ticks, 1)() end
end

local available = true
local catalog = {}
local ready = {} -- 书目 id → 已可打开路径
local scans = 0
local prepared = {}
package.preload["source.kindle.client"] = function()
    return {
        available = function() return available end,
        scan = function()
            scans = scans + 1
            if catalog == false then return nil, "cc.db query failed" end
            return catalog
        end,
        readyPath = function(kbook) return ready[kbook.id] end,
        prepare = function(kbook)
            prepared[#prepared + 1] = kbook.id
            if kbook.fail then return nil, kbook.fail end
            return "/kcache/" .. kbook.id .. ".epub"
        end,
        reasonText = function(code) return "reason:" .. tostring(code) end,
    }
end

local reconciled, touched, released = {}, {}, 0
local touch_ok = true
package.preload["book.store"] = function()
    return {
        reconcile = function(source_id, books)
            reconciled[#reconciled + 1] = { source_id = source_id, books = books }
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        end,
        touch = function(path, identity)
            touched[#touched + 1] = { path = path, identity = identity }
            if not touch_ok then return false, "failed to register book path" end
            return true
        end,
    }
end
package.preload["db.book"] = function()
    return { releaseForeignPaths = function(source_id)
        Assert.eq(source_id, "kindle")
        released = released + 1
        return true
    end }
end

local jobs = {}
package.preload["workers.job"] = function()
    return { run = function(worker, opts)
        local job = { worker = worker, opts = opts, cancelled = false }
        function job:cancel() self.cancelled = true end
        jobs[#jobs + 1] = job
        return job
    end }
end

local Kindle = require("source.kindle")

-- 未装 kindle.koplugin：数据源列表里不出现，但实例仍可建（换源残留配置不崩）。
available = false
Assert.is_nil(Kindle.meta())
Assert.is_false(Kindle.new():configured())
available = true
Assert.eq(Kindle.meta().id, "kindle")
Assert.eq(Kindle.meta().type, "book")

local source = Kindle.new()
Assert.is_true(source:configured())
Assert.is_true(source:capabilities().search)
Assert.is_false(source:capabilities().scrape)
-- 无远端：进度 / 笔记 / 统计的协议方法都不提供，各域由 book.* 判 unsupported。
Assert.is_nil(source.getProgressAsync)
Assert.is_nil(source.putProgressAsync)
Assert.is_nil(source.pushNotesAsync)
Assert.is_nil(source.pushStatsAsync)

catalog = {
    { id = "cc:a", title = "三体", authors = { "刘慈欣" }, open_mode = "convert", source_path = "/docs/a.kfx" },
    { id = "cc:b", title = "Dune", authors = {}, open_mode = "direct", source_path = "/docs/b.azw3" },
    { id = "cc:c", title = "云端书", authors = {}, open_mode = "blocked", block_reason = "missing_source" },
    { id = "cc:d", title = "DRM 书", authors = {}, open_mode = "blocked", block_reason = "drm" },
}
ready = { ["cc:a"] = "/kcache/cc_a.epub", ["cc:b"] = "/docs/b.azw3" }

-- ── 书架：cc.db 快照 reconcile，只收可读的书；已可打开的书登记 path 并撤掉 local 旧占位 ──
do
    local result, err
    source:syncBooksAsync(nil, function(r, e) result, err = r, e end)
    Assert.is_nil(result, "同步必须异步回调")
    flush()
    Assert.is_nil(err)
    Assert.eq(result.pulled, 2)
    Assert.len(reconciled, 1)
    Assert.eq(reconciled[1].source_id, "kindle")
    local books = reconciled[1].books
    Assert.len(books, 2)
    Assert.eq(books[1].stable_id, "cc:a")
    Assert.eq(books[1].source_id, "kindle")
    Assert.eq(books[1].title, "三体")
    Assert.eq(books[1].authors, "刘慈欣")
    Assert.eq(books[1].path, "/kcache/cc_a.epub")
    Assert.eq(books[2].stable_id, "cc:b")
    Assert.is_nil(books[2].authors, "空作者列表不写空串")
    Assert.eq(books[2].path, "/docs/b.azw3")
    Assert.eq(released, 1)
end

-- ── dirty_only（关书推脏）不扫 cc.db ──
do
    local before = scans
    local result
    source:syncBooksAsync({ dirty_only = true }, function(r) result = r end)
    flush()
    Assert.is_true(result.skipped)
    Assert.eq(scans, before)
end

-- ── cc.db 读失败：透传错误，不 reconcile（否则整架被下架） ──
do
    local saved = catalog
    catalog = false
    local result, err
    source:syncBooksAsync(nil, function(r, e) result, err = r, e end)
    flush()
    Assert.is_nil(result)
    Assert.eq(err, "cc.db query failed")
    Assert.len(reconciled, 1)
    catalog = saved
end

local function open(stable_id)
    local out = {}
    local handle = source:openBookAsync({ source_id = "kindle", stable_id = stable_id }, nil, function(path, err)
        out.called, out.path, out.err = true, path, err
    end)
    return out, handle
end

-- ── 已就绪（direct 原文件 / 新鲜转换缓存）：直接登记并返回，不起子进程 ──
do
    local out = open("cc:b")
    flush()
    Assert.eq(out.path, "/docs/b.azw3")
    Assert.eq(touched[#touched].path, "/docs/b.azw3")
    Assert.eq(touched[#touched].identity.stable_id, "cc:b")
    Assert.len(jobs, 0)
    Assert.eq(released, 2)
end

-- ── 未就绪的 KFX：heavy 子进程转换，完成后登记路径 ──
do
    ready["cc:a"] = nil
    local out = open("cc:a")
    flush()
    Assert.is_nil(out.called)
    Assert.len(jobs, 1)
    Assert.eq(jobs[1].opts.kind, "heavy")
    local res = jobs[1].worker()
    Assert.eq(prepared[1], "cc:a")
    jobs[1].opts.on_done(res)
    Assert.eq(out.path, "/kcache/cc:a.epub")
    Assert.eq(touched[#touched].path, "/kcache/cc:a.epub")
end

-- ── 转换失败：用 kindle.koplugin 的失败文案，不登记路径 ──
do
    catalog[1].fail = "drm_key_extraction_failed"
    local touches = #touched
    local out = open("cc:a")
    flush()
    local job = jobs[#jobs]
    job.opts.on_done(job.worker())
    Assert.is_nil(out.path)
    Assert.eq(out.err, "reason:drm_key_extraction_failed")
    Assert.eq(#touched, touches)
    catalog[1].fail = nil
end

-- ── 取消：杀子进程，之后的结果不回调 ──
do
    local out, handle = open("cc:a")
    flush()
    local job = jobs[#jobs]
    handle:cancel()
    Assert.is_true(job.cancelled)
    job.opts.on_done(job.worker())
    Assert.is_nil(out.called)
end

-- ── 不可读书目：给出原因；书目里没有的 id 重扫一次后报找不到 ──
do
    local out = open("cc:d")
    flush()
    Assert.eq(out.err, "reason:drm")

    local before = scans
    out = open("cc:gone")
    flush()
    Assert.eq(scans, before + 1)
    Assert.eq(out.err, "Kindle 书库中找不到这本书")
end

-- ── 新实例（未同步过）打开：先扫书目再打开 ──
do
    local fresh = Kindle.new()
    local before = scans
    local out = {}
    fresh:openBookAsync({ source_id = "kindle", stable_id = "cc:b" }, nil, function(path) out.path = path end)
    flush()
    Assert.eq(scans, before + 1)
    Assert.eq(out.path, "/docs/b.azw3")
end

-- ── 登记失败：不交出路径（否则阅读期认不出身份） ──
do
    touch_ok = false
    local out = open("cc:b")
    flush()
    Assert.is_nil(out.path)
    Assert.eq(out.err, "failed to register book path")
    touch_ok = true
end
