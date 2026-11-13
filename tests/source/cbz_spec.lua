--[[--
共用 CBZ 打包器走 cbz_fit：按序写出切片页；番茄 / 快看 / 拷贝 / 知音漫客都经此入口。

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
    nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
}
package.loaded["ui.guard"] = {
    wrap = function(_name, fn) return fn end,
}

-- 打包已改走 workers.job（heavy）；单测里不 fork，把 worker 挂到同一套 ticks 上。
local jobs = {}
package.loaded["workers.job"] = {
    run = function(worker, opts)
        local job = {
            name = opts.name,
            kind = opts.kind,
            cancelled = false,
        }
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

local function drain()
    while #ticks > 0 do
        local fn = table.remove(ticks, 1)
        fn()
    end
end

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/moon-cbz-spec"
os.execute("mkdir -p '" .. dir .. "'")

local function writeFile(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

do -- 宽图缩小、高图切片后按序成为独立页
    added, ticks = {}, {}
    local src1 = dir .. "/page_a.jpg"
    local src2 = dir .. "/page_b.jpg"
    writeFile(src1, "wide")
    writeFile(src2, "tall")
    Fit.backend = {
        materialize = function(path, dest, start, screen_w, _screen_h)
            Assert.eq(screen_w, 1072)
            os.execute("mkdir -p '" .. dest .. "'")
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
    -- 让 rename 成功：先让 .part 在 build 开头被删掉，结束时 writer 不真正写文件，
    -- 所以这里把目标路径预先写成空，改用 os.rename 可用的假 .part。
    local old_rename = os.rename
    local renamed = {}
    os.rename = function(from, to)
        renamed[#renamed + 1] = { from, to }
        if from:sub(-5) == ".part" then
            writeFile(to, "cbz")
            os.remove(from)
            return true
        end
        return old_rename(from, to)
    end
    package.loaded["device"] = {
        screen = {
            getWidth = function() return 1072 end,
            getHeight = function() return 1448 end,
        },
    }
    local result, err
    Cbz.build({ src1, src2 }, archive, { cancelled = false }, function(path, reason)
        result, err = path, reason
    end)
    drain()
    os.rename = old_rename
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
    -- 源图在打包成功后删除；切片临时文件也应清掉。
    Assert.is_nil(io.open(src1, "rb"))
    Assert.is_nil(io.open(src2, "rb"))
end

do -- 所有漫画源都走共用打包器
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

do -- 非漫画路径打开前不拦截
    local called
    local handle = Cbz.ensureAsync("/library/book.epub", function(path, err)
        called = { path, err }
    end)
    Assert.eq(called[1], "/library/book.epub")
    Assert.is_nil(called[2])
    handle.cancel()
end

do -- 过大的已缓存 CBZ 打开前会重打包
    local rebuilt = {}
    local orig_rebuild = Cbz.rebuild
    local orig_ready = Cbz.ready
    local orig_needs = Cbz.needsFit
    Cbz.ready = function() return true end
    Cbz.needsFit = function(path)
        Assert.eq(path, "/cache/fanqie/767.cbz")
        return true, 2
    end
    Cbz.rebuild = function(path, _state, cb)
        rebuilt[#rebuilt + 1] = path
        cb(path, nil, { old_pages = 2, new_pages = 5 })
    end
    local started = false
    local result
    Cbz.ensureAsync("/cache/fanqie/767.cbz", function(path)
        result = path
    end, { on_rebuild = function() started = true end })
    Cbz.rebuild = orig_rebuild
    Cbz.ready = orig_ready
    Cbz.needsFit = orig_needs
    Assert.is_true(started)
    Assert.eq(rebuilt[1], "/cache/fanqie/767.cbz")
    Assert.eq(result, "/cache/fanqie/767.cbz")
end

do -- Reader 的路径索引属于实例：未 iterate 的新实例不能直接按路径提取。
    local Paths = require("utils.paths")
    local sandbox = require("support.config").dir() .. "/cbz-reader-spec"
    Assert.is_true(Paths.ensureDir(sandbox))
    local archive = sandbox .. "/cached.cbz"
    local header = "\137PNG\r\n\26\n" .. string.rep("\0", 4) .. "IHDR"
        .. string.char(0, 0, 8, 96, 0, 0, 7, 208)
    local readers, broken, empty = {}, false, false
    local original_archiver = package.loaded["ffi/archiver"]
    local original_docsettings = package.loaded["docsettings"]
    local sidecar, flushed = { last_page = 1, doc_pages = 1 }, 0
    package.loaded["docsettings"] = {
        hasSidecarFile = function() return true end,
        open = function()
            return {
                readSetting = function(_self, key) return sidecar[key] end,
                saveSetting = function(_self, key, value) sidecar[key] = value end,
                flush = function() flushed = flushed + 1 end,
            }
        end,
    }
    package.loaded["ffi/archiver"] = {
        Reader = {
            new = function()
                local reader = { entries = {} }
                readers[#readers + 1] = reader
                function reader:open(path)
                    return path ~= sandbox .. "/missing.cbz"
                end
                function reader:iterate()
                    local yielded = false
                    return function()
                        if empty or yielded then return nil end
                        yielded = true
                        local entry = { path = "page.png", mode = "file", size = #header }
                        self.entries[entry.path] = entry
                        return entry
                    end
                end
                function reader:extractToMemory(name)
                    if self.entries[name] then return header end
                end
                function reader:extractToPath(name, dest)
                    if not self.entries[name] or broken then
                        self.err = "extract failed"
                        return false
                    end
                    writeFile(dest, header)
                    return true
                end
                function reader:close() self.closed = true end
                return reader
            end,
        },
        Writer = {
            new = function()
                return {
                    open = function(_self, path) writeFile(path, "rebuilt"); return true end,
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
    writeFile(archive, "original")
    local needed, count = Cbz.needsFit(archive, 1072, 1448)
    Assert.is_true(needed)
    Assert.eq(count, 1)
    Assert.is_true(readers[#readers].closed)
    added, ticks = {}, {}
    local sidecar_during_pack
    Fit.backend = { materialize = function(path)
        sidecar_during_pack = { last_page = sidecar.last_page, doc_pages = sidecar.doc_pages, flushed = flushed }
        return {
            { path = path, name = "0001.png", temp = false },
            { path = path, name = "0002.png", temp = false },
        }
    end }
    local result, reason, meta
    Cbz.rebuild(archive, {}, function(path, err, info) result, reason, meta = path, err, info end, 1072, 1448)
    drain()
    Assert.eq(result, archive)
    Assert.is_nil(reason)
    Assert.eq(meta.old_pages, 1)
    Assert.eq(meta.new_pages, 2)
    Assert.eq(jobs[#jobs].name, "cbz.rebuild")
    Assert.eq(jobs[#jobs].kind, "heavy")
    Assert.len(added, 2)
    Assert.eq(added[1].data, header)
    Assert.is_true(readers[#readers].closed)
    -- 边车只在子进程返回后由父进程改；打包过程中不得动 DocSettings。
    Assert.eq(sidecar_during_pack.last_page, 1)
    Assert.eq(sidecar_during_pack.doc_pages, 1)
    Assert.eq(sidecar_during_pack.flushed, 0)
    Assert.eq(sidecar.last_page, 1)
    Assert.eq(sidecar.doc_pages, 2)
    Assert.eq(flushed, 1)

    broken = true
    local before = assert(io.open(archive, "rb"))
    local content = before:read("*a")
    before:close()
    Cbz.rebuild(archive, {}, function(path, err) result, reason = path, err end, 1072, 1448)
    drain()
    Assert.is_nil(result)
    Assert.eq(reason, "extract failed")
    Assert.is_true(readers[#readers].closed)
    Assert.eq(flushed, 1, "失败时不能重写阅读进度")
    local after = assert(io.open(archive, "rb"))
    Assert.eq(after:read("*a"), content, "提取失败不能替换原归档")
    after:close()
    Assert.is_nil(io.open(archive .. ".part", "rb"))

    header = "\137PNG\r\n\26\n" .. string.rep("\0", 4) .. "IHDR"
        .. string.char(0, 0, 2, 0, 0, 0, 2, 0)
    Assert.is_false(Cbz.needsFit(archive, 1072, 1448))
    empty = true
    Assert.is_false(Cbz.needsFit(archive, 1072, 1448))
    Cbz.rebuild(archive, {}, function(path, err) result, reason = path, err end, 1072, 1448)
    Assert.is_nil(result)
    Assert.not_nil(reason)
    Assert.is_true(readers[#readers].closed)
    Assert.is_false(Cbz.needsFit(sandbox .. "/missing.cbz", 1072, 1448))

    empty, broken = false, false
    added, ticks, jobs = {}, {}, {}
    writeFile(archive, "original")
    writeFile(archive .. ".part", "partial")
    local cancelled_called = false
    local cancel_state = { cancelled = false }
    Fit.backend = { materialize = function(path)
        return { { path = path, name = "0001.png", temp = false } }
    end }
    Cbz.rebuild(archive, cancel_state, function() cancelled_called = true end, 1072, 1448)
    Assert.not_nil(cancel_state.job)
    Assert.eq(cancel_state.job.kind, "heavy")
    Assert.is_true(type(cancel_state.writer.close) == "function")
    Assert.is_nil(cancel_state.writer.addFileFromMemory)
    Cbz.abort(cancel_state, archive)
    drain()
    Assert.is_false(cancelled_called)
    Assert.is_true(cancel_state.cancelled)
    Assert.is_true(jobs[#jobs].cancelled)
    Assert.is_nil(cancel_state.job)
    Assert.is_nil(cancel_state.writer)
    local kept = assert(io.open(archive, "rb"))
    Assert.eq(kept:read("*a"), "original", "取消不能替换原归档")
    kept:close()
    Assert.is_nil(io.open(archive .. ".part", "rb"))
    Assert.is_nil(io.open(archive .. ".old", "rb"))
    Assert.is_nil(require("libs/libkoreader-lfs").attributes(archive .. ".src"))
    Assert.is_nil(require("libs/libkoreader-lfs").attributes(archive .. ".fit"))

    for _idx, rollback_fails in ipairs({ false, true }) do
        writeFile(archive, "original")
        local failed_state = {}
        local calls = 0
        local old_rename = os.rename
        os.rename = function(from, to)
            if from == archive .. ".part" then return nil, "replacement failed" end
            if rollback_fails and from == archive .. ".old" then return nil, "rollback failed" end
            return old_rename(from, to)
        end
        Cbz.rebuild(archive, failed_state, function(path, err)
            calls = calls + 1
            result, reason = path, err
        end, 1072, 1448)
        drain()
        os.rename = old_rename
        Assert.eq(calls, 1)
        Assert.is_nil(result)
        Assert.matches(reason, "replacement failed")
        Assert.is_nil(failed_state.job)
        Assert.is_nil(failed_state.writer)
        Assert.eq(flushed, 1, "替换失败不能改阅读进度")
        Assert.is_nil(io.open(archive .. ".part", "rb"))
        local original_path = rollback_fails and archive .. ".old" or archive
        local original = assert(io.open(original_path, "rb"))
        Assert.eq(original:read("*a"), "original")
        original:close()
        if rollback_fails then
            Assert.matches(reason, "rollback failed")
            Assert.is_true(reason:find(archive .. ".old", 1, true) ~= nil)
            Cbz.clearWork(archive)
            Cbz.abort(failed_state, archive)
            local backup = assert(io.open(archive .. ".old", "rb"))
            Assert.eq(backup:read("*a"), "original", "清理和取消不能删未恢复的原件")
            backup:close()
            -- 即使调用方重新建了归档，下一次重建也不能覆盖未恢复的备份。
            writeFile(archive, "new archive")
            local job_count = #jobs
            Cbz.rebuild(archive, {}, function(path, err) result, reason = path, err end, 1072, 1448)
            Assert.is_nil(result)
            Assert.is_true(reason:find(archive .. ".old", 1, true) ~= nil)
            Assert.eq(#jobs, job_count)
            backup = assert(io.open(archive .. ".old", "rb"))
            Assert.eq(backup:read("*a"), "original")
            backup:close()
            os.remove(archive .. ".old")
        else
            Assert.eq(reason, "replacement failed")
            Assert.is_nil(io.open(archive .. ".old", "rb"))
        end
    end

    Fit.backend = nil
    package.loaded["ffi/archiver"] = original_archiver
    package.loaded["docsettings"] = original_docsettings
    os.remove(archive)
    require("libs/libkoreader-lfs").rmdir(sandbox)
end

do -- 打包进度走 Job.on_progress；成功后删源图
    added, ticks, jobs = {}, {}, {}
    local src = dir .. "/progress.jpg"
    writeFile(src, "page")
    local seen = {}
    local state = {
        cancelled = false,
        on_progress = function(value) seen[#seen + 1] = value end,
    }
    Fit.backend = { materialize = function(path)
        return { { path = path, name = "0001.jpg", temp = false } }
    end }
    package.loaded["device"] = {
        screen = {
            getWidth = function() return 1072 end,
            getHeight = function() return 1448 end,
        },
    }
    local old_rename = os.rename
    os.rename = function(from, to)
        if from:sub(-5) == ".part" then
            writeFile(to, "cbz")
            os.remove(from)
            return true
        end
        return old_rename(from, to)
    end
    local result, err
    Cbz.build({ src }, dir .. "/progress.cbz", state, function(path, reason)
        result, err = path, reason
    end)
    drain()
    os.rename = old_rename
    Fit.backend = nil
    Assert.is_nil(err)
    Assert.eq(result, dir .. "/progress.cbz")
    Assert.len(seen, 1)
    Assert.eq(seen[1].done, 1)
    Assert.eq(seen[1].total, 1)
    Assert.is_nil(io.open(src, "rb"))
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
    local archive = require("support.config").dir() .. "/cbz-fork-failure.cbz"
    Cbz.build({}, archive, state, function(_path, err) reason = err end)
    Assert.eq(reason, "fork failed")
    Assert.is_nil(state.job)
    Assert.is_nil(state.writer)

    state = {}
    local launches = 0
    package.loaded["workers.job"].run = function(worker, opts)
        launches = launches + 1
        if launches == 1 then
            opts.on_failed("fork failed")
            return dead
        end
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

os.execute("rm -rf '" .. dir .. "'")
return true
