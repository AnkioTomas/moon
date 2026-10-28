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
