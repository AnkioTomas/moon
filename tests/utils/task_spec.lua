--[[--
utils.task：子进程轮询任务

@module tests.utils.task_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()

local alive = true
local terminated = false
local pipe_payload = "7"
local spawn_ok = true
local spawn_err = "spawn failed"
local last_with_pipe = nil

package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function(worker, with_pipe)
            last_with_pipe = with_pipe
            if not spawn_ok then
                return nil, spawn_err
            end
            -- 模拟子进程：真正调用 worker，以便 Task.inSubProcess 置位
            if type(worker) == "function" then
                worker(42, with_pipe and 99 or nil)
            end
            if with_pipe then
                return 42, 99
            end
            return 42
        end,
        isSubProcessDone = function()
            return not alive
        end,
        terminateSubProcess = function()
            terminated = true
            alive = false
        end,
        readAllFromFD = function()
            return pipe_payload
        end,
        writeToFD = function() end,
    }
end

package.loaded["utils.task"] = nil
package.loaded["ffi/util"] = nil

local Task = require("utils.task")

Assert.is_true(not Task.inSubProcess())

-- 成功：on_done 收到 pipe 数据；worker 内 inSubProcess 为 true
do
    Stubs.reset()
    alive = true
    terminated = false
    spawn_ok = true
    local done_raw, failed_err
    local saw_sub
    local job = Task.run(function()
        saw_sub = Task.inSubProcess()
    end, {
        pipe = true,
        on_done = function(raw) done_raw = raw end,
        on_failed = function(err) failed_err = err end,
    })
    Assert.eq(last_with_pipe, true)
    Assert.is_true(saw_sub)
    Assert.is_nil(done_raw)
    alive = false
    Stubs.flush()
    Assert.eq(done_raw, "7")
    Assert.is_nil(failed_err)
    Assert.eq(type(job.abort), "function")
end

-- 启动失败 → on_failed
do
    Stubs.reset()
    package.loaded["utils.task"] = nil
    package.loaded["ffi/util"] = nil
    spawn_ok = false
    Task = require("utils.task")
    local done_hit, failed_err = false, nil
    Task.run(function() end, {
        on_done = function() done_hit = true end,
        on_failed = function(err) failed_err = err end,
    })
    Stubs.flush()
    Assert.eq(done_hit, false)
    Assert.eq(failed_err, "spawn failed")
    spawn_ok = true
end

-- 外部 abort 后不再回调
do
    Stubs.reset()
    package.loaded["utils.task"] = nil
    package.loaded["ffi/util"] = nil
    alive = true
    terminated = false
    Task = require("utils.task")
    local done_hit, failed_hit = false, false
    local job = Task.run(function() end, {
        timeout = 30,
        on_done = function() done_hit = true end,
        on_failed = function() failed_hit = true end,
    })
    job:abort()
    Assert.eq(terminated, true)
    alive = false
    Stubs.flush()
    Assert.eq(done_hit, false)
    Assert.eq(failed_hit, false)
end

-- timeout → abort 并 on_failed("timeout")
do
    Stubs.reset()
    package.loaded["utils.task"] = nil
    package.loaded["ffi/util"] = nil
    alive = true
    terminated = false
    Task = require("utils.task")
    local done_hit, failed_err = false, nil
    Task.run(function() end, {
        timeout = 1,
        on_done = function() done_hit = true end,
        on_failed = function(err) failed_err = err end,
    })
    -- stubs 忽略 delay：同一次 flush 里 check 会再挂一拍，timeout 回调也会入队并执行
    Stubs.flush()
    Assert.eq(done_hit, false)
    Assert.eq(failed_err, "timeout")
    Assert.eq(terminated, true)
end

-- 无 pipe 时 on_done(nil)
do
    Stubs.reset()
    package.loaded["utils.task"] = nil
    package.loaded["ffi/util"] = nil
    alive = false
    Task = require("utils.task")
    local raw_seen = "unset"
    Task.run(function() end, {
        on_done = function(raw) raw_seen = raw end,
    })
    Assert.is_nil(last_with_pipe)
    Stubs.flush()
    Assert.is_nil(raw_seen)
end

io.write("ok\n")
