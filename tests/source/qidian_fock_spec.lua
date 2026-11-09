--[[--
起点 VIP 章节解密（Fock 转译版）离线用例。

@module tests.source.qidian_fock_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local Sample = require("support.qidian_fock_sample")
local Fock = require("source.qidian.fock")

local plain, err = Fock.decrypt(Sample.content, Sample.chapter_id, Sample.keypool, Sample.version, Sample.uid)
Assert.is_nil(err)
Assert.eq(#plain, 13654)
Assert.eq(plain:sub(1, 3), "<p>")
Assert.matches(plain, "光王街")

-- 子进程任务：worker 结果经 on_done 交回
local Job = require("workers.job")
local real_run = Job.run
Job.run = function(worker, opts) opts.on_done(worker(function() end)); return {} end
local async_text
Fock.decryptAsync(Sample.content, Sample.chapter_id, Sample.keypool, Sample.version, Sample.uid,
    function(text) async_text = text end)
Job.run = real_run
Assert.eq(async_text, plain)

-- 共用宿主 source.yuewen_fock：decrypt 期间关 JIT、完事恢复原状；jobAsync 子进程抛错经 cb(nil, err) 交回
do
    local Shared = require("source.yuewen_fock")
    local Text = require("utils.text")
    local was_on = jit.status()
    local seen_off
    local decode = Text.base64Decode
    Text.base64Decode = function(...)
        seen_off = not jit.status()
        return decode(...)
    end

    -- 字体路径由主进程持有：取消只清自己的文件，失败 / 成功也清理，退出前不抢删。
    do
        local Shared = require("source.yuewen_fock")
        local lfs = require("libs/libkoreader-lfs")
        local pending = {}
        Job.run = function(worker, opts)
            local job = { poll = 0.5 }
            pending[#pending + 1] = { worker = worker, opts = opts, job = job }
            return job
        end
        local files = {}
        local function worker(paths)
            files[#files + 1] = paths
            for index, path in ipairs(paths) do
                local file = assert(io.open(path, "wb"))
                assert(file:write("font-" .. index))
                assert(file:close())
            end
            return { text = "restored" }
        end
        local text, err
        local function done(value, reason) text, err = value, reason end
        Shared.jobAsync("font_cancel", worker, done)
        Shared.jobAsync("font_failed", worker, done)
        pending[1].worker()
        pending[2].worker()
        pending[1].opts.on_cancelled(pending[1].job)
        Assert.is_nil(text)
        for _idx, path in ipairs(files[1]) do Assert.is_nil(lfs.attributes(path)) end
        for _idx, path in ipairs(files[2]) do Assert.eq(lfs.attributes(path, "mode"), "file") end
        pending[2].opts.on_failed("timeout")
        Assert.is_nil(text)
        Assert.eq(err, "timeout")
        for _idx, path in ipairs(files[2]) do Assert.is_nil(lfs.attributes(path)) end

        Shared.jobAsync("font_done", worker, done)
        pending[3].opts.on_done(pending[3].worker())
        Assert.eq(text, "restored")
        Assert.is_nil(err)
        for _idx, path in ipairs(files[3]) do Assert.is_nil(lfs.attributes(path)) end

        Shared.jobAsync("font_exiting", worker, done)
        pending[4].worker()
        pending[4].job.pid = 123
        local ffiUtil = require("ffi/util")
        local UIManager = require("ui/uimanager")
        local real_done, real_schedule = ffiUtil.isSubProcessDone, UIManager.scheduleIn
        local exited, tick = false, nil
        ffiUtil.isSubProcessDone = function() return exited end
        UIManager.scheduleIn = function(_self, _delay, fn) tick = fn end
        pending[4].opts.on_cancelled(pending[4].job)
        for _idx, path in ipairs(files[4]) do Assert.eq(lfs.attributes(path, "mode"), "file") end
        Assert.eq(type(tick), "function")
        exited = true
        tick()
        for _idx, path in ipairs(files[4]) do Assert.is_nil(lfs.attributes(path)) end
        ffiUtil.isSubProcessDone, UIManager.scheduleIn = real_done, real_schedule
        Job.run = real_run
    end
    local text = Fock.decrypt(Sample.content, Sample.chapter_id, Sample.keypool, Sample.version, Sample.uid)
    Text.base64Decode = decode
    Assert.eq(#text, 13654)
    Assert.is_true(seen_off, "解密期间 JIT 关着")
    Assert.eq(jit.status(), was_on, "解密完 JIT 开关恢复")

    local Job = require("workers.job")
    local real_run = Job.run
    Job.run = function(worker, opts)
        local ok, res = pcall(worker)
        if ok then opts.on_done(res) else opts.on_failed(res) end
        return {}
    end
    local got_text, got_err
    Shared.jobAsync("t", function() return { text = "ok" } end, function(t, e) got_text, got_err = t, e end)
    Assert.eq(got_text, "ok")
    Assert.is_nil(got_err)
    Shared.jobAsync("t", function() error("boom", 0) end, function(t, e) got_text, got_err = t, e end)
    Assert.is_nil(got_text)
    Assert.eq(got_err, "boom")
    Job.run = real_run
end
