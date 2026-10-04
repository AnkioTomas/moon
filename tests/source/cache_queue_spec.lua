--[[--
章节全本缓存任务：同类并行、同书执行中拒绝、可恢复错误重试与完成提示、未结束任务上限。

@module tests.source.cache_queue_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

package.preload["l10n"] = function()
    return { apply = function() end }
end
package.preload["gettext"] = function()
    return function(text) return text end
end

local scheduled = {}
local notices = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, delay, fn)
            scheduled[#scheduled + 1] = { delay = delay, fn = fn }
        end,
        show = function(_, widget)
            notices[#notices + 1] = widget.text
        end,
    }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return true end }
end
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o) require("ui/uimanager"):show(o) end

local callbacks = {}
local source = {
    id = "wechat",
    cacheAllChaptersAsync = function(_, _, progress, cb)
        progress(0, 35)
        callbacks[#callbacks + 1] = cb
        return { cancel = function() end }
    end,
}

local Queue = require("source.cache_queue")
local Tasks = require("workers.tasks")
local ref = { source_id = "wechat", stable_id = "book-1" }
local function enqueue(identity) return Tasks.enqueue(Queue.spec(source, identity)) end
local job = enqueue(ref)
Assert.not_nil(job)
Assert.eq(#callbacks, 1)
Assert.eq(Tasks.tasks()[1].state, "running")
Assert.eq(Tasks.tasks()[1].total, 35)
Assert.eq(Tasks.tasks()[1].title, "book-1")
Assert.eq(Tasks.tasks()[1].kind, "cache")
Assert.is_true(Queue.has("wechat", "book-1"))
Assert.is_false(Queue.has("wechat", "book-2"))

-- 同一本书不得并发重复缓存。
local same, why = enqueue(ref)
Assert.is_nil(same)
Assert.eq(why, "running")

-- 425 退避 15 秒后重试；已缓存章节由 source.chapter 自动跳过。
callbacks[1](false, 34, "HTTP 425", 35, 1)
Assert.eq(Tasks.tasks()[1].state, "retry_wait")
Assert.eq(#notices, 0, "可重试失败不提示")
local other = enqueue({ source_id = "wechat", stable_id = "book-2" })
Assert.not_nil(other)
Assert.eq(#callbacks, 2, "同类并行：第一本退避中第二本照常开跑")
Assert.eq(Tasks.tasks()[2].title, "book-2")
local retry_schedule
for _, item in ipairs(scheduled) do
    if item.delay == 15 then retry_schedule = item break end
end
Assert.not_nil(retry_schedule)
retry_schedule.fn()
Assert.eq(#callbacks, 3, "退避结束后第一本续跑")
Assert.eq(job.attempt, 2)

callbacks[3](true, 35, nil, 35, 0)
Assert.is_true(job.done)
Assert.eq(job.result.cached, 35)
Assert.eq(job.result.total, 35)
Assert.eq(notices[#notices], "全本缓存完成：35 / 35 章")
callbacks[2](true, 10, nil, 10, 0)
Assert.is_true(other.done)
Assert.eq(#Tasks.tasks(), 0)
Assert.is_false(Queue.has("wechat", "book-1"))

-- 未结束任务满 64 个后拒绝入队，并带 queue_full（同类并行时在跑的也算）
do
    local accepted = 0
    local reason
    for i = 1, 80 do
        local next_job, why = enqueue({ stable_id = "fill-" .. i })
        if not next_job then
            reason = why
            break
        end
        accepted = accepted + 1
    end
    Assert.eq(accepted, 64)
    Assert.eq(reason, "queue_full")
end
