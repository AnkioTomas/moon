--[[--
book.store.verifyDownloadsAsync：手动删掉的下载文件，刷新时撤掉登记。

子进程只 stat（这里用同步假 Job 直接跑 worker），主进程复核后批量写库。

@module tests.book.store_verify_spec
--]]

local Assert = require("support.assert")

local existing = {} -- path → true
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            if not existing[path] then return nil end
            return field == "mode" and "file" or { mode = "file" }
        end,
    }
end
package.preload["utils.paths"] = function() return {} end
package.preload["utils.log"] = function()
    return { warn = function() end, dbg = function() end, info = function() end }
end
package.preload["db.base"] = function() return {} end
package.preload["source.toc"] = function() return { TTL = 3600 } end

local book_rows, chapter_paths = {}, {}
local cleared, deleted = nil, nil
local write_ok = true
local scopes = {}
package.preload["db.book"] = function()
    return {
        pathsBySource = function(scope)
            scopes[#scopes + 1] = scope
            return book_rows
        end,
        clearPaths = function(rows) cleared = rows; return write_ok end,
    }
end
package.preload["db.chapter"] = function()
    return {
        pathsBySource = function() return chapter_paths end,
        deleteMany = function(paths) deleted = paths; return true end,
    }
end

-- 假 Job：记录参数，由用例决定何时「子进程」跑完、何时文件状态变化。
local jobs = {}
package.preload["workers.job"] = function()
    return {
        run = function(worker, opts)
            local job = { worker = worker, opts = opts }
            jobs[#jobs + 1] = job
            return job
        end,
    }
end

for _, name in ipairs({ "book.store" }) do package.loaded[name] = nil end
local Store = require("book.store")

--- 在「子进程」里跑 worker，再把结果交回主进程回调。
local function finish(job)
    job.opts.on_done(job.worker())
end

-- 没有登记路径：不起子进程，cb 不调用。
local calls = 0
Assert.is_nil(Store.verifyDownloadsAsync("moon", function() calls = calls + 1 end))
Assert.len(jobs, 0)
Assert.eq(calls, 0)

-- 整本书 + 章节：只撤掉文件不存在的那些；范围原样透传。
book_rows = {
    { source_id = "moon", stable_id = "a", path = "/c/a.epub" },
    { source_id = "wechat", stable_id = "b", path = "/c/b.epub" },
}
chapter_paths = { "/c/w/1.html", "/c/w/2.html", "/c/w/3.html" }
existing = { ["/c/a.epub"] = true, ["/c/w/1.html"] = true }
local changed
local job = Store.verifyDownloadsAsync({ "moon", "wechat" }, function(n) changed = n end)
Assert.not_nil(job)
Assert.eq(jobs[1].opts.kind, "light", "stat 放子进程，不卡界面")
Assert.eq(scopes[#scopes][2], "wechat")
finish(jobs[1])
Assert.eq(changed, 3)
Assert.len(cleared, 1)
Assert.eq(cleared[1].stable_id, "b")
Assert.eq(cleared[1].path, "/c/b.epub", "带原路径写库，校验期间改写过的行不动")
Assert.len(deleted, 2)
Assert.eq(deleted[1], "/c/w/2.html")
Assert.eq(deleted[2], "/c/w/3.html")

-- 子进程说缺失、回主进程前又下载回来：复核后不撤。
cleared, deleted, changed = nil, nil, nil
existing = {}
Store.verifyDownloadsAsync("moon", function(n) changed = n end)
local missing = jobs[2].worker()
existing = { ["/c/a.epub"] = true, ["/c/b.epub"] = true, ["/c/w/2.html"] = true }
jobs[2].opts.on_done(missing)
Assert.eq(changed, 2)
Assert.is_nil(cleared, "整本书都回来了，不写 books")
Assert.len(deleted, 2)
Assert.eq(deleted[1], "/c/w/1.html")
Assert.eq(deleted[2], "/c/w/3.html")

-- 全部都在：不写库，changed=0。
cleared, deleted = nil, nil
existing = { ["/c/a.epub"] = true, ["/c/b.epub"] = true,
    ["/c/w/1.html"] = true, ["/c/w/2.html"] = true, ["/c/w/3.html"] = true }
Store.verifyDownloadsAsync("moon", function(n) changed = n end)
finish(jobs[3])
Assert.eq(changed, 0)
Assert.is_nil(cleared)
Assert.is_nil(deleted)

-- 写库失败不计数；子进程失败回调 0。
existing = {}
write_ok = false
Store.verifyDownloadsAsync("moon", function(n) changed = n end)
finish(jobs[4])
Assert.eq(changed, 3, "books 写失败只计章节")
write_ok = true
Store.verifyDownloadsAsync("moon", function(n) changed = n end)
jobs[5].opts.on_failed("boom")
Assert.eq(changed, 0)

package.loaded["book.store"] = nil
