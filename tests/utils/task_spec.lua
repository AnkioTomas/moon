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
local stream_payload = ""
local stream_mode = false
local read_error = false
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
            local payload = stream_mode and stream_payload or pipe_payload
            stream_payload = ""
            stream_mode = false
            return payload
        end,
        getNonBlockingReadSize = function()
            return #stream_payload
        end,
        writeToFD = function(_, data)
            stream_mode = true
            stream_payload = stream_payload .. data
            return true
        end,
    }
end

package.preload["ffi/posix"] = function()
    local ffi = require("ffi")
    return {
        read = function(_, buffer, size)
            if read_error then
                error("io boom")
            end
            ffi.copy(buffer, stream_payload, size)
            stream_payload = stream_payload:sub(size + 1)
            return size
        end,
    }
end

package.preload["json"] = function()
    return {
        encode = function(value)
            return value.phase .. "|" .. tostring(value.count)
        end,
        decode = function(raw)
            local phase, count = raw:match("^([^|]+)|(%d+)$")
            if not phase then
                error("invalid json")
            end
            return { phase = phase, count = tonumber(count) }
        end,
    }
end

package.loaded["utils.task"] = nil
package.loaded["ffi/util"] = nil
package.loaded["ffi/posix"] = nil
package.loaded["json"] = nil

local Task = require("utils.task")

Assert.is_true(not Task.inSubProcess())
Assert.errors(function()
    Task.post({ phase = "scan", count = 0 })
end, "only available")
Assert.errors(function()
    Task.run(function() end, { pipe = true, on_message = function() end })
end, "mutually exclusive")

-- on_message：Task.post 经 pipe 回到主进程，且不改变 on_done(nil) 语义
do
    Stubs.reset()
    alive = true
    stream_payload = ""
    stream_mode = false
    local messages = {}
    local done_raw = "unset"
    Task.run(function()
        Task.post({ phase = "scan", count = 1 })
        Task.post({ phase = "scan", count = 2 })
    end, {
        on_message = function(message)
            messages[#messages + 1] = message
        end,
        on_done = function(raw)
            done_raw = raw
        end,
    })
    Assert.eq(last_with_pipe, true)
    alive = false
    Stubs.flush()
    Assert.len(messages, 2)
    Assert.eq(messages[1].phase, "scan")
    Assert.eq(messages[1].count, 1)
    Assert.eq(messages[2].count, 2)
    Assert.is_nil(done_raw)
end

-- on_message 回调异常 → on_failed（不断轮询链），协议失败杀子进程，后续消息不派
do
    Stubs.reset()
    alive = true
    stream_payload = ""
    stream_mode = false
    terminated = false
    local received = {}
    local done_hit, failed_err = false, nil
    Task.run(function()
        Task.post({ phase = "scan", count = 1 })
        Task.post({ phase = "scan", count = 2 })
    end, {
        on_message = function(message)
            received[#received + 1] = message.count
            error("ui boom")
        end,
        on_done = function() done_hit = true end,
        on_failed = function(err) failed_err = err end,
    })
    -- 注意保持 alive=true：协议失败时子进程还活着，应被 terminate
    Stubs.flush()
    Assert.len(received, 1)
    Assert.eq(done_hit, false)
    Assert.matches(failed_err, "on_message failed")
    Assert.is_true(terminated)
end

-- 损坏帧头 → on_failed + 杀子进程
do
    Stubs.reset()
    alive = true
    stream_payload = "zzzzzzzzpayload"
    stream_mode = true
    terminated = false
    local failed_err
    Task.run(function() end, {
        on_message = function() end,
        on_done = function() end,
        on_failed = function(err) failed_err = err end,
    })
    Stubs.flush()
    Assert.matches(failed_err, "invalid message frame")
    Assert.is_true(terminated)
end

-- 残缺帧（子进程已结束时清账）→ on_failed
do
    Stubs.reset()
    alive = false
    stream_payload = "00000010ab" -- 声称 16 字节，只给了 2
    stream_mode = true
    local done_hit, failed_err = false, nil
    Task.run(function() end, {
        on_message = function() end,
        on_done = function() done_hit = true end,
        on_failed = function(err) failed_err = err end,
    })
    Stubs.flush()
    Assert.eq(done_hit, false)
    Assert.matches(failed_err, "incomplete message frame")
end

-- 读管道抛错 → on_failed + 杀子进程（不能裸抛断轮询链）
do
    Stubs.reset()
    alive = true
    stream_payload = "x"
    stream_mode = true
    read_error = true
    terminated = false
    local failed_err
    Task.run(function() end, {
        on_message = function() end,
        on_failed = function(err) failed_err = err end,
    })
    Stubs.flush()
    Assert.matches(failed_err, "pipe read failed")
    Assert.is_true(terminated)
    read_error = false
end

-- 成功：on_done 收到 pipe 数据；worker 内 inSubProcess 为 true
do
    Stubs.reset()
    alive = true
    terminated = false
    spawn_ok = true
    stream_payload = ""
    stream_mode = false
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
