--[[--
漫画书源下载页图后共用 CBZ 打包器：按序写出切片页，失败与取消保留源图。

@module tests.source.cbz_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local added = {}
package.loaded["ffi/archiver"] = {
    Writer = {
        new = function()
            return {
                open = function() return true end,
                setZipCompression = function() return true end,
                addFileFromMemory = function(_self, name, data)
                    added[#added + 1] = { name = name, data = data }
                    return true
                end,
                close = function() end,
            }
        end,
    },
}

local ticks = {}
package.loaded["ui/uimanager"] = {
    nextTick = function(_self, fn) ticks[#ticks + 1] = fn end,
}
package.loaded["ui.guard"] = {
    wrap = function(_name, fn) return fn end,
}

local jobs = {}
package.loaded["workers.job"] = {
    run = function(worker, opts)
        local job = { name = opts.name, kind = opts.kind, cancelled = false }
        function job.cancel()
            if job.cancelled then return end
            job.cancelled = true
            if opts.on_cancelled then opts.on_cancelled(job) end
        end
        jobs[#jobs + 1] = job
        ticks[#ticks + 1] = function()
            if job.cancelled then return end
            local ok, result = pcall(worker, function(value)
                if opts.on_progress then opts.on_progress(value) end
            end)
            if job.cancelled then return end
            if not ok then
                if opts.on_failed then opts.on_failed(result) end
                return
            end
            if opts.on_done then opts.on_done(result) end
        end
        return job
    end,
}

local Cbz = require("source.cbz")
local Fit = require("source.cbz_fit")
local lfs = require("libs/libkoreader-lfs")
local dir = require("support.config").dir() .. "/cbz-assembly-spec"
assert(require("utils.paths").ensureDir(dir))
package.loaded["device"] = {
    screen = {
        getWidth = function() return 1072 end,
        getHeight = function() return 1448 end,
    },
}

local function drain()
    while #ticks > 0 do
        local fn = table.remove(ticks, 1)
        fn()
    end
end

local function writeFile(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

do -- 下载的宽图缩小、条漫切片后按序成为独立页。
    local src1, src2 = dir .. "/page_a.jpg", dir .. "/page_b.jpg"
    writeFile(src1, "wide")
    writeFile(src2, "tall")
    Fit.backend = {
        materialize = function(path, dest, start, screen_w, _screen_h)
            Assert.eq(screen_w, 1072)
            assert(require("utils.paths").ensureDir(dest))
            if path == src1 then
                return { { path = path, name = Fit.pageName(start, ".jpg"), temp = false } }
            end
            local pages = {}
            for i = 1, 3 do
                local name = Fit.pageName(start + i - 1, ".jpg")
                local out = dest .. "/" .. name
                writeFile(out, "slice-" .. i)
                pages[i] = { path = out, name = name, temp = true }
            end
            return pages
        end,
    }
    local archive = dir .. "/chapter.cbz"
    writeFile(archive .. ".part", "stale")
    local rename = os.rename
    os.rename = function(from, to)
        if from:sub(-5) == ".part" then
            writeFile(to, "cbz")
            os.remove(from)
            return true
        end
        return rename(from, to)
    end
    local result, err
    Cbz.build({ src1, src2 }, archive, { cancelled = false }, function(path, reason)
        result, err = path, reason
    end)
    drain()
    os.rename = rename
    Fit.backend = nil
    Assert.is_nil(err)
    Assert.eq(result, archive)
    Assert.eq(jobs[#jobs].name, "cbz.build")
    Assert.eq(jobs[#jobs].kind, "heavy")
    Assert.len(added, 4)
    Assert.eq(added[1].name, "0001.jpg")
    Assert.eq(added[2].name, "0002.jpg")
    Assert.eq(added[3].name, "0003.jpg")
    Assert.eq(added[4].name, "0004.jpg")
    Assert.eq(added[2].data, "slice-1")
    Assert.eq(added[4].data, "slice-3")
    Assert.is_nil(lfs.attributes(src1))
    Assert.is_nil(lfs.attributes(src2))
    Assert.is_nil(lfs.attributes(dir .. "/chapter.fit"))
end

do -- 所有漫画源都走共用打包器。
    local files = {
        "book.koplugin/source/fanqie/comic.lua",
        "book.koplugin/source/kuaikan/chapter.lua",
        "book.koplugin/source/copymanga/chapter.lua",
        "book.koplugin/source/zymk/chapter.lua",
    }
    for _idx, rel in ipairs(files) do
        local file = assert(io.open(rel, "r"))
        local src = file:read("*a")
        file:close()
        Assert.is_true(src:find('require%("source%.cbz"%)', 1) ~= nil, rel)
        Assert.is_true(src:find("Cbz%.build", 1) ~= nil, rel)
        Assert.is_nil(src:find("cbz_fit", 1, true), rel)
    end
end

do -- 打包进度经 Job 回传，最终文件保存失败不能删源图。
    local src, archive = dir .. "/progress.jpg", dir .. "/progress.cbz"
    writeFile(src, "page")
    local seen = {}
    local state = { on_progress = function(value) seen[#seen + 1] = value end }
    Fit.backend = { materialize = function(path)
        return { { path = path, name = "0001.jpg", temp = false } }
    end }
    local rename = os.rename
    os.rename = function() return nil, "read-only filesystem" end
    local result, reason
    Cbz.build({ src }, archive, state, function(path, err) result, reason = path, err end)
    drain()
    os.rename = rename
    Assert.is_nil(result)
    Assert.eq(reason, "read-only filesystem")
    Assert.len(seen, 1)
    Assert.eq(seen[1].done, 1)
    Assert.eq(seen[1].total, 1)
    Assert.is_true(Cbz.ready(src))
    Assert.is_nil(lfs.attributes(archive .. ".part"))
    Assert.is_nil(state.job)
    Assert.is_nil(state.writer)
    Fit.backend = nil
end

do -- 切片失败保留源图，清理半成品。
    local src, archive = dir .. "/broken.jpg", dir .. "/broken.cbz"
    writeFile(src, "page")
    Fit.backend = { materialize = function() return nil, "slice failed" end }
    local result, reason
    Cbz.build({ src }, archive, {}, function(path, err) result, reason = path, err end)
    drain()
    Fit.backend = nil
    Assert.is_nil(result)
    Assert.eq(reason, "slice failed")
    Assert.is_true(Cbz.ready(src))
    Assert.is_nil(lfs.attributes(archive))
    Assert.is_nil(lfs.attributes(archive .. ".part"))
end

do -- 漫画源的 writer:close() 仍可取消子进程，不删源图、不通知成功。
    local src, archive = dir .. "/cancel.jpg", dir .. "/cancel.cbz"
    writeFile(src, "page")
    writeFile(archive .. ".part", "partial")
    local state, called = {}, false
    Cbz.build({ src }, archive, state, function() called = true end)
    local job = state.job
    Assert.not_nil(job)
    state.writer:close()
    drain()
    Assert.is_true(job.cancelled)
    Assert.is_true(state.cancelled)
    Assert.is_false(called)
    Assert.is_true(Cbz.ready(src))
    Assert.is_nil(lfs.attributes(archive .. ".part"))
    Assert.is_nil(state.job)
    Assert.is_nil(state.writer)
end

do -- fork 同步失败不能挂回死句柄，也不能覆盖错误回调里立即发起的重试。
    local Job = package.loaded["workers.job"]
    local dead = { settled = true, state = "failed", cancel = function() end }
    local state = {}
    package.loaded["workers.job"] = {
        run = function(_worker, opts)
            opts.on_failed("fork failed")
            return dead
        end,
    }
    local reason
    local archive = dir .. "/fork-failure.cbz"
    Cbz.build({}, archive, state, function(_path, err) reason = err end)
    Assert.eq(reason, "fork failed")
    Assert.is_nil(state.job)
    Assert.is_nil(state.writer)
    state = {}
    local launches = 0
    package.loaded["workers.job"].run = function(worker, opts)
        launches = launches + 1
        if launches == 1 then opts.on_failed("fork failed"); return dead end
        return Job.run(worker, opts)
    end
    Cbz.build({}, archive, state, function(_path, err)
        Assert.eq(err, "fork failed")
        Cbz.build({}, archive, state, function() error("cancelled retry completed") end)
    end)
    local retry = jobs[#jobs]
    Assert.eq(state.job, retry)
    Cbz.abort(state, archive)
    Assert.is_true(retry.cancelled)
    Assert.is_nil(state.job)
    Assert.is_nil(state.writer)
    drain()
    package.loaded["workers.job"] = Job
end

for name in lfs.dir(dir) do
    if name ~= "." and name ~= ".." then assert(os.remove(dir .. "/" .. name)) end
end
assert(lfs.rmdir(dir))
return true
