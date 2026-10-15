--[[--
后台任务队列：同类并行、异类互斥、队首异类不被同类插队、同 key 排队替换 / 执行中拒绝、取消、同步完成、迟到回调、
重试上限（退避占执行权）、休眠暂停 / 唤醒续跑、断网失败等网络、未结束任务上限。

@module tests.tasks_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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

local guarded = {}
package.preload["ui.guard"] = function()
    return {
        call = function(label, fn, ...)
            local res = { pcall(fn, ...) }
            if res[1] then return unpack(res, 2) end
            guarded[#guarded + 1] = label
        end,
    }
end

local Tasks = require("workers.tasks")

--- 造一个手动控制完成的任务；runs 记录每次启动的 { report, done, cancelled }。
local function spec(key, kind, extra)
    local runs = {}
    local t = {
        key = key,
        kind = kind,
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

-- 类型只有 download / sync / cache / online。
Assert.errors(function() Tasks.enqueue(spec("bad", "other")) end, "unknown task kind")
local online_ok = Tasks.enqueue(spec("online-ok", "online"))
Assert.eq(online_ok.kind, "online")
online_ok.runs[1].done({ ok = true })
Assert.eq(#Tasks.tasks(), 0)

-- 同类并行；异类等执行权；队首是异类时后面的同类不插队。
local c1 = Tasks.enqueue(spec("c1", "cache"))
local c2 = Tasks.enqueue(spec("c2", "cache"))
local s1 = Tasks.enqueue(spec("s1", "sync"))
local c3 = Tasks.enqueue(spec("c3", "cache"))
Assert.eq(#c1.runs, 1)
Assert.eq(#c2.runs, 1, "同类并行")
Assert.eq(#s1.runs, 0, "异类等执行权")
Assert.eq(#c3.runs, 0, "队首是异类时同类不插队")
local snapshot = Tasks.tasks()
Assert.eq(snapshot[1].key, "c1")
Assert.eq(snapshot[1].kind, "cache")
Assert.eq(snapshot[2].key, "c2")
Assert.eq(snapshot[3].key, "s1")
Assert.eq(snapshot[3].state, "queued")
Assert.eq(snapshot[4].key, "c3")

-- 进度上报进快照。
c1.runs[1].report("正在下载", 3, 9)
Assert.eq(Tasks.tasks()[1].text, "正在下载")
Assert.eq(Tasks.tasks()[1].count, 3)
Assert.eq(Tasks.tasks()[1].total, 9)

-- key 必填；同 key 已在执行：拒绝，原任务不动。
Assert.errors(function() Tasks.enqueue(spec(nil, "cache")) end, "task key required")
Assert.errors(function() Tasks.enqueue(spec("", "cache")) end, "task key required")
local same, why = Tasks.enqueue(spec("c1", "cache"))
Assert.is_nil(same)
Assert.eq(why, "running")
Assert.eq(Tasks.get("c1"), c1)

-- 同 key 尚未执行：踢掉旧的（不调 on_done、从未启动），新任务排到队尾。
local c3_done = false
c3.on_done = function() c3_done = true end
local c3b = Tasks.enqueue(spec("c3", "cache"))
Assert.is_true(c3.done)
Assert.eq(c3.state, "cancelled")
Assert.is_false(c3_done)
Assert.eq(#c3.runs, 0)
Assert.eq(Tasks.get("c3"), c3b)
Assert.eq(Tasks.tasks()[4].key, "c3")
Assert.eq(#Tasks.tasks(), 4)
c3 = c3b

-- 完成：on_done 一次；同类还有在跑的，异类继续等。
local finished = {}
c2.on_done = function(result) finished[#finished + 1] = result end
c1.runs[1].done({ ok = true })
Assert.is_true(c1.done)
Assert.is_nil(Tasks.get("c1"))
Assert.eq(#s1.runs, 0, "同类还有在跑的")
-- 迟到的重复 done / report 忽略。
c1.runs[1].done({ ok = false })
c1.runs[1].report("迟到", 1, 1)
Assert.eq(c1.result.ok, true)

-- 取消运行中的任务：杀句柄、不调 on_done、之后的 done 忽略；同类全部让出后异类开跑。
c2.cancel()
Assert.is_true(c2.runs[1].cancelled)
Assert.eq(c2.state, "cancelled")
Assert.eq(#finished, 0)
c2.runs[1].done({ ok = true })
Assert.eq(#finished, 0)
Assert.eq(#s1.runs, 1, "同类全部让出，异类开跑")
Assert.eq(#c3.runs, 0)

-- 取消排队中的任务：从未启动（同类 s2 也排在异类 c3 后面）。
local s2 = Tasks.enqueue(spec("s2", "sync"))
Assert.eq(#s2.runs, 0)
s2.cancel()
Assert.eq(#s2.runs, 0)
Assert.is_nil(Tasks.get("s2"))
s1.runs[1].done({})
Assert.eq(#c3.runs, 1)
c3.runs[1].done({})
Assert.eq(#Tasks.tasks(), 0)

-- run 内同步完成：不残留执行权，后面的任务照常启动。
local sync_done = 0
local d1 = Tasks.enqueue{
    key = "d1", kind = "download",
    run = function(_, done) done({ ok = true }); return { cancel = function() end } end,
    on_done = function() sync_done = sync_done + 1 end,
}
Assert.is_true(d1.done)
Assert.eq(sync_done, 1)
local d2 = Tasks.enqueue(spec("d2", "sync"))
Assert.eq(#d2.runs, 1)
d2.runs[1].done({})

-- 重试：退避时占执行权，异类不开跑；最多 3 次后照常结束。
local r_done
local r = Tasks.enqueue(spec("r", "download", {
    retryable = function(result) return result.again end,
    on_done = function(result) r_done = result end,
}))
local r_next = Tasks.enqueue(spec("r2", "cache"))
r.runs[1].done({ again = true })
Assert.eq(r.state, "retry_wait")
Assert.eq(#r_next.runs, 0, "退避期间异类不开跑")
Assert.eq(select(2, Tasks.enqueue(spec("r", "download"))), "running", "退避中算执行中")
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
local w = Tasks.enqueue(spec("w", "download", { retryable = function() return true end }))
w.runs[1].done({})
local pending_tick = w.retry_tick
w.cancel()
Assert.eq(unscheduled[#unscheduled], pending_tick)
Assert.is_nil(Tasks.get("w"))

-- 观察者：合并通知，cancel 只注销观察者。
local notified = 0
local watch = Tasks.watch(function() notified = notified + 1 end)
local x = Tasks.enqueue(spec("x", "download"))
for _, item in ipairs(scheduled) do
    if item.delay == 0.25 then item.fn() end
end
Assert.is_true(notified >= 1)
watch.cancel()
Assert.eq(#x.runs, 1, "注销观察者不影响任务")
x.runs[1].done({})
Assert.eq(#Tasks.tasks(), 0)

-- 休眠：在跑的 restartable 任务被中断放回 waiting，不耗重试次数；不可重跑的（书架同步）不动。
local owned = Tasks.enqueue(spec("owned", "download"))
local dl = Tasks.enqueue(spec("dl", "download", { restartable = true }))
local p1 = Tasks.enqueue(spec("p1", "cache", { restartable = true }))
dl.runs[1].report(nil, 3, 10)
Tasks.onSuspend()
Assert.is_true(dl.runs[1].cancelled)
Assert.eq(dl.state, "waiting")
Assert.eq(dl.attempt, 0)
Assert.eq(select(2, Tasks.enqueue(spec("dl", "download"))), "running", "等网络算执行中")
Assert.is_false(owned.runs[1].cancelled)
Assert.eq(owned.state, "running")
-- 被中断的那次回调迟到也忽略。
dl.runs[1].done({ ok = false })
Assert.eq(dl.state, "waiting")
-- 快照顺序：运行中 → 等网络 → 排队；进度保留。
local snap = Tasks.tasks()
Assert.eq(snap[1].key, "owned")
Assert.eq(snap[2].key, "dl")
Assert.eq(snap[2].state, "waiting")
Assert.eq(snap[2].count, 3)
Assert.eq(snap[3].key, "p1")
Assert.is_true(snap[2].restartable)
Assert.is_false(snap[1].restartable)
owned.runs[1].done({ ok = true })
Assert.eq(#p1.runs, 0, "休眠中执行权空出来也不启动 restartable 任务")

-- 唤醒：按原顺序续跑，dl 先开跑，异类 p1 等。
Tasks.onResume()
Assert.eq(#dl.runs, 2)
Assert.eq(dl.attempt, 1)
Assert.eq(#p1.runs, 0)

-- 断网导致的失败：放回 waiting，不调 on_done、不耗次数；等网络不占执行权，异类照常尝试。
local dl_done
dl.on_done = function(result) dl_done = result end
connected = false
dl.runs[2].done({ ok = false, err = "connect failed" })
Assert.eq(dl.state, "waiting")
Assert.is_nil(dl_done)
Assert.eq(dl.attempt, 0)
Assert.eq(#p1.runs, 1)
p1.runs[1].done({ ok = false })
Assert.eq(p1.state, "waiting")
-- 联网后按原顺序续跑；联网时的失败照常结束。
connected = true
Tasks.onNetworkConnected()
Assert.eq(#dl.runs, 3)
Assert.eq(#p1.runs, 1, "异类等 dl 让出")
dl.runs[3].done({ ok = false, err = "HTTP 500" })
Assert.eq(dl_done.err, "HTTP 500")
Assert.eq(#p1.runs, 2)
p1.runs[2].done({ ok = true })
Assert.eq(#Tasks.tasks(), 0)

-- 不可重跑的任务断网失败照常结束。
local o_done
local o = Tasks.enqueue(spec("o2", "sync", { on_done = function(result) o_done = result end }))
connected = false
o.runs[1].done({ ok = false })
Assert.not_nil(o_done)
connected = true

-- 已结束历史：新的在前、带成败、取消的不记；同 key 只留最新；最多 10 条；不影响未结束快照。
do
    local history = Tasks.finished()
    Assert.eq(history[1].key, "o2")
    Assert.eq(history[1].state, "finished")
    Assert.is_false(history[1].ok)
    Assert.eq(history[2].key, "p1")
    Assert.is_true(history[2].ok)
    for _idx, item in ipairs(history) do
        Assert.is_true(item.key ~= "c2" and item.key ~= "s2", "取消的不记")
    end
    history[1] = nil
    Assert.eq(Tasks.finished()[1].key, "o2", "返回副本")
    local again = Tasks.enqueue(spec("o2", "sync"))
    again.runs[1].done({ ok = true })
    history = Tasks.finished()
    Assert.eq(history[1].key, "o2")
    Assert.is_true(history[1].ok)
    local count = 0
    for _idx, item in ipairs(history) do
        if item.key == "o2" then count = count + 1 end
    end
    Assert.eq(count, 1, "同 key 只留最新")
    for i = 1, 12 do
        Tasks.enqueue(spec("h" .. i, "sync")).runs[1].done({ ok = true })
    end
    history = Tasks.finished()
    Assert.len(history, 10)
    Assert.eq(history[1].key, "h12")
    Assert.eq(history[10].key, "h3")
    Assert.eq(#Tasks.tasks(), 0)
end

-- run 同步抛错 / on_done 抛错：按失败结算并报告，队列不被占死，异类照常开跑。
do
    local results = {}
    local bad = Tasks.enqueue(spec("crash", "download", {
        run = function() error("boom") end,
        on_done = function(result)
            results[#results + 1] = result
            error("on_done boom")
        end,
    }))
    Assert.eq(bad.state, "finished")
    Assert.is_false(bad.result.ok)
    Assert.len(results, 1)
    Assert.contains(guarded, "task run download")
    Assert.contains(guarded, "task on_done download")
    local next_task = Tasks.enqueue(spec("after-crash", "sync"))
    Assert.eq(#next_task.runs, 1, "崩溃任务不再占执行权")
    next_task.runs[1].done({ ok = true })
end

-- convert（双语对照 / 重新排版）：与任何类型并行；同一本书只一个；取消停掉句柄；完成 / 失败都调 on_done。
do
    local sync = Tasks.enqueue(spec("conv-sync", "sync"))
    local results = {}
    local tr = Tasks.enqueue(spec("bilingual\0local\0a", "convert", {
        restartable = true,
        on_done = function(result) results[#results + 1] = result end,
    }))
    Assert.eq(#tr.runs, 1, "不等书架同步")
    local dup, why = Tasks.enqueue(spec("bilingual\0local\0a", "convert"))
    Assert.is_nil(dup)
    Assert.eq(why, "running")
    tr.runs[1].report("正在翻译…", 3, 10)
    Assert.eq(Tasks.get(tr.key).count, 3)
    tr.cancel()
    Assert.is_true(tr.runs[1].cancelled)
    Assert.eq(tr.state, "cancelled")
    Assert.is_nil(Tasks.get(tr.key))
    Assert.len(results, 0, "取消不调 on_done")
    local again = Tasks.enqueue(spec("bilingual\0local\0a", "convert", {
        on_done = function(result) results[#results + 1] = result end,
    }))
    again.runs[1].done({ ok = false, err = "HTTP 500" })
    Assert.is_false(results[1].ok)
    local rf = Tasks.enqueue(spec("reflow\0local\0a", "convert", {
        on_done = function(result) results[#results + 1] = result end,
    }))
    rf.runs[1].done({ ok = true, file = "/x" })
    Assert.is_true(results[2].ok)
    sync.runs[1].done({ ok = true })
end

-- 未结束任务满 64 个后拒绝入队，带 queue_full（同类并行时在跑的也算）。
do
    local accepted, reason = 0, nil
    for i = 1, 80 do
        local job, why = Tasks.enqueue(spec("fill-" .. i, "cache"))
        if not job then
            reason = why
            break
        end
        accepted = accepted + 1
    end
    Assert.eq(accepted, 64)
    Assert.eq(reason, "queue_full")
end

return true
