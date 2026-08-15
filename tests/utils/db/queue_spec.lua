--[[--
utils.db.queue 离线用例：串行队列状态机。

驱动方式：UIManager:nextTick 已被 stub 入队，用 Stubs.flush() 同步冲刷。

@module tests.utils.db.queue_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local Queue = require("utils.db.queue")

-- 入队后不会立即执行（不堵 UI），flush 后才跑
do
    local ran = 0
    Queue.run(function()
        ran = ran + 1
    end)
    Assert.eq(ran, 0)
    Stubs.flush()
    Assert.eq(ran, 1)
end

-- 多个任务按入队顺序执行，且各执行一次
do
    local order = {}
    for i = 1, 3 do
        Queue.run(function()
            order[#order + 1] = i
        end)
    end
    Stubs.flush()
    Assert.eq(table.concat(order, ","), "1,2,3")
end

-- 成功任务走 on_done(nil)
do
    local done_calls = 0
    local done_raw = "unset"
    Queue.run(function()
    end, {
        on_done = function(raw)
            done_calls = done_calls + 1
            done_raw = raw
        end,
    })
    Stubs.flush()
    Assert.eq(done_calls, 1)
    Assert.is_nil(done_raw)
end

-- 失败任务走 on_failed(err)，err 为 pcall 抛出的错误
do
    local failed_err
    Queue.run(function()
        error("boom")
    end, {
        on_failed = function(err)
            failed_err = err
        end,
    })
    Stubs.flush()
    Assert.not_nil(failed_err)
    Assert.matches(failed_err, "boom")
end

-- 单个任务报错被隔离：后续任务仍按序执行
do
    local order = {}
    Queue.run(function()
        order[#order + 1] = "a"
    end)
    Queue.run(function()
        error("mid boom")
    end, {
        on_failed = function()
            order[#order + 1] = "failed"
        end,
    })
    Queue.run(function()
        order[#order + 1] = "b"
    end)
    Stubs.flush()
    Assert.eq(table.concat(order, ","), "a,failed,b")
end

-- 任务报错且未提供 on_failed：错误被吞掉，不炸队列，后续任务照常执行
do
    local ran = false
    Queue.run(function()
        error("silent boom")
    end)
    Queue.run(function()
        ran = true
    end)
    Stubs.flush()
    Assert.is_true(ran)
end

-- 同时给 on_done/on_failed：成功只走 on_done，失败只走 on_failed
do
    local done_called = false
    local failed_called = false
    Queue.run(function()
    end, {
        on_done = function()
            done_called = true
        end,
        on_failed = function()
            failed_called = true
        end,
    })
    Queue.run(function()
        error("x")
    end, {
        on_done = function()
            done_called = false
        end,
        on_failed = function()
            failed_called = true
        end,
    })
    Stubs.flush()
    Assert.is_true(done_called)
    Assert.is_true(failed_called)
end

-- worker 执行期间再入队：新任务仍会在同一轮 flush 中被后续 nextTick 驱动执行
do
    local order = {}
    Queue.run(function()
        order[#order + 1] = "outer"
        Queue.run(function()
            order[#order + 1] = "inner"
        end)
    end)
    Stubs.flush()
    Assert.eq(table.concat(order, ","), "outer,inner")
end

-- clear() 清空待执行任务：已入队但未执行的全部丢弃
do
    local ran = 0
    for _ = 1, 3 do
        Queue.run(function()
            ran = ran + 1
        end)
    end
    Queue.clear()
    Stubs.flush()
    Assert.eq(ran, 0)
end

-- clear() 后队列可继续正常使用
do
    local ran = false
    Queue.run(function()
        ran = true
    end)
    Queue.clear()
    Queue.run(function()
        ran = true
    end)
    Stubs.flush()
    Assert.is_true(ran)
end

-- 回调自身抛错被隔离：不卡死队列，后续任务照常执行
do
    local order = {}
    Queue.run(function()
    end, {
        on_done = function()
            order[#order + 1] = "cb"
            error("callback boom")
        end,
    })
    Queue.run(function()
        order[#order + 1] = "next"
    end)
    Stubs.flush()
    Assert.eq(table.concat(order, ","), "cb,next")
end

-- flush 幂等：空队列冲刷无副作用
do
    Stubs.flush()
    Stubs.flush()
    Assert.is_true(true)
end
