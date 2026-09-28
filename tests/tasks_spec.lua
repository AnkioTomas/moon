--[[--
后台任务队列：lane 内串行、lane 间并行、去重、取消、同步完成、迟到回调、重试上限、
休眠暂停 / 唤醒续跑、断网失败等网络。

@module tests.tasks_spec
--]]

local Assert = require("support.assert")

local scheduled, unscheduled = {}, {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, fn)
            scheduled[#scheduled + 1] = { delay = delay, fn = fn }
        end,
        unschedule = function(_, fn)
            unscheduled[#unscheduled + 1] = fn
        end,
    }
end

local connected = true
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end

local Tasks = require("tasks")

--- 造一个手动控制完成的任务；runs 记录每次启动的 { report, done, cancelled }。
local function spec(key, lane, extra)
    local runs = {}
    local t = {
        key = key,
        lane = lane,
        label = "L",
        title = key,
        runs = runs,
        run = function(report, done)
            local r = { report = report, done = done, cancelled = false }
            runs[#runs + 1] = r
            return { cancel = function() r.cancelled = true end }
        end,
    }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end

-- lane 内串行，lane 间并行。
local a1 = Tasks.enqueue(spec("a1", "a"))
local a2 = Tasks.enqueue(spec("a2", "a"))
local b1 = Tasks.enqueue(spec("b1", "b"))
Assert.eq(#a1.runs, 1)
Assert.eq(#a2.runs, 0, "同 lane 排队")
Assert.eq(#b1.runs, 1, "不同 lane 不等")
local snapshot = Tasks.tasks()
Assert.eq(snapshot[1].key, "a1")
Assert.eq(snapshot[2].key, "b1")
Assert.eq(snapshot[3].key, "a2")
Assert.eq(snapshot[3].state, "queued")

-- 进度上报进快照。
a1.runs[1].report("正在下载", 3, 9)
Assert.eq(Tasks.tasks()[1].text, "正在下载")
Assert.eq(Tasks.tasks()[1].count, 3)
Assert.eq(Tasks.tasks()[1].total, 9)

-- 同 key 复用。
local same, queued = Tasks.enqueue(spec("a1", "a"))
Assert.eq(same, a1)
Assert.is_false(queued)

-- 完成：on_done 一次，让出 lane。
local finished = {}
a2.on_done = function(result) finished[#finished + 1] = result end
a1.runs[1].done({ ok = true })
Assert.is_true(a1.done)
Assert.is_nil(Tasks.get("a1"))
Assert.eq(#a2.runs, 1)
-- 迟到的重复 done / report 忽略。
a1.runs[1].done({ ok = false })
a1.runs[1].report("迟到", 1, 1)
Assert.eq(a1.result.ok, true)

-- 取消运行中的任务：杀句柄、不调 on_done、之后的 done 忽略、让出 lane。
local a3 = Tasks.enqueue(spec("a3", "a"))
a2.cancel()
Assert.is_true(a2.runs[1].cancelled)
Assert.eq(a2.state, "cancelled")
Assert.eq(#finished, 0)
a2.runs[1].done({ ok = true })
Assert.eq(#finished, 0)
Assert.eq(#a3.runs, 1)

-- 取消排队中的任务：从未启动。
local a4 = Tasks.enqueue(spec("a4", "a"))
a4.cancel()
Assert.eq(#a4.runs, 0)
Assert.is_nil(Tasks.get("a4"))
a3.runs[1].done({})
b1.runs[1].done({})
Assert.eq(#Tasks.tasks(), 0)

-- run 内同步完成：不残留占槽，排在后面的照常启动。
local sync_done = 0
local s1 = Tasks.enqueue{
    key = "s1", lane = "s", label = "S",
    run = function(_, done) done({ ok = true }); return { cancel = function() end } end,
    on_done = function() sync_done = sync_done + 1 end,
}
Assert.is_true(s1.done)
Assert.eq(sync_done, 1)
local s2 = Tasks.enqueue(spec("s2", "s"))
Assert.eq(#s2.runs, 1)
s2.runs[1].done({})

-- 重试：退避时占 lane；最多 3 次后照常结束。
local r_done
local r = Tasks.enqueue(spec("r", "r", {
    retryable = function(result) return result.again end,
    on_done = function(result) r_done = result end,
}))
local r_next = Tasks.enqueue(spec("r2", "r"))
r.runs[1].done({ again = true })
Assert.eq(r.state, "retry_wait")
Assert.eq(#r_next.runs, 0, "退避期间不让后面的任务开跑")
local tick = scheduled[#scheduled]
Assert.eq(tick.delay, 15)
tick.fn()
Assert.eq(#r.runs, 2)
r.runs[2].done({ again = true })
Assert.eq(scheduled[#scheduled].delay, 30)
scheduled[#scheduled].fn()
r.runs[3].done({ again = true, n = 3 })
Assert.eq(r_done.n, 3, "第 3 次失败不再重试")
Assert.eq(#r_next.runs, 1)
r_next.runs[1].done({})

-- 退避中取消：撤掉定时器。
local w = Tasks.enqueue(spec("w", "w", { retryable = function() return true end }))
w.runs[1].done({})
local pending_tick = w.retry_tick
w.cancel()
Assert.eq(unscheduled[#unscheduled], pending_tick)
Assert.is_nil(Tasks.get("w"))

-- 观察者：合并通知，cancel 只注销观察者。
local notified = 0
local watch = Tasks.watch(function() notified = notified + 1 end)
local x = Tasks.enqueue(spec("x", "x"))
for _, item in ipairs(scheduled) do
    if item.delay == 0.25 then item.fn() end
end
Assert.is_true(notified >= 1)
watch.cancel()
Assert.eq(#x.runs, 1, "注销观察者不影响任务")
x.runs[1].done({})
Assert.eq(#Tasks.tasks(), 0)

-- 休眠：在跑的 restartable 任务被中断放回 waiting，不耗重试次数；不可重跑的（书架同步）不动。
local p1 = Tasks.enqueue(spec("p1", "p", { restartable = true }))
local p2 = Tasks.enqueue(spec("p2", "p", { restartable = true }))
local owned = Tasks.enqueue(spec("owned", "o"))
p1.runs[1].report("第 3 章", 3, 10)
Tasks.suspend()
Assert.is_true(p1.runs[1].cancelled)
Assert.eq(p1.state, "waiting")
Assert.eq(p1.attempt, 0)
Assert.eq(#p2.runs, 0, "休眠中不启动 restartable 任务")
Assert.is_false(owned.runs[1].cancelled)
Assert.eq(owned.state, "running")
-- 被中断的那次回调迟到也忽略。
p1.runs[1].done({ ok = false })
Assert.eq(p1.state, "waiting")
-- 快照顺序：运行中 → 等网络 → 排队；进度保留。
local snap = Tasks.tasks()
Assert.eq(snap[1].key, "owned")
Assert.eq(snap[2].key, "p1")
Assert.eq(snap[2].state, "waiting")
Assert.eq(snap[2].count, 3)
Assert.eq(snap[3].key, "p2")
Assert.is_true(snap[2].restartable)
Assert.is_false(snap[1].restartable)
owned.runs[1].done({ ok = true })

-- 唤醒：按原顺序续跑，p1 先于 p2。
Tasks.wake()
Assert.eq(#p1.runs, 2)
Assert.eq(p1.attempt, 1)
Assert.eq(#p2.runs, 0)

-- 断网导致的失败：放回 waiting，不调 on_done、不耗次数；同 lane 下一个照常尝试。
local p1_done
p1.on_done = function(result) p1_done = result end
connected = false
p1.runs[2].done({ ok = false, err = "connect failed" })
Assert.eq(p1.state, "waiting")
Assert.is_nil(p1_done)
Assert.eq(p1.attempt, 0)
Assert.eq(#p2.runs, 1)
p2.runs[1].done({ ok = false })
Assert.eq(p2.state, "waiting")
-- 联网后续跑；联网时的失败照常结束。
connected = true
Tasks.wake()
Assert.eq(#p1.runs, 3)
p1.runs[3].done({ ok = false, err = "HTTP 500" })
Assert.eq(p1_done.err, "HTTP 500")
Assert.eq(#p2.runs, 2)
p2.runs[2].done({ ok = true })
Assert.eq(#Tasks.tasks(), 0)

-- 不可重跑的任务断网失败照常结束。
local o_done
local o = Tasks.enqueue(spec("o2", "o", { on_done = function(r) o_done = r end }))
connected = false
o.runs[1].done({ ok = false })
Assert.not_nil(o_done)
connected = true

return true
