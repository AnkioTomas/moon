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
