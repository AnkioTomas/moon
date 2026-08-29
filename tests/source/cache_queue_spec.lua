--[[--
章节后台缓存队列：串行、去重和可恢复错误重试。

@module tests.source.cache_queue_spec
--]]

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
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end

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
local ref = { source_id = "wechat", stable_id = "book-1" }
local job, queued = Queue.enqueue(source, ref)
Assert.is_true(queued)
Assert.eq(#callbacks, 1)
Assert.eq(Queue.status().state, "running")
Assert.eq(Queue.status().total, 35)

-- 同一本书不得并发重复缓存。
local same, queued_again = Queue.enqueue(source, ref)
Assert.eq(same, job)
Assert.is_false(queued_again)

-- 425 退避 15 秒后重试；已缓存章节由 source.chapter 自动跳过。
callbacks[1](false, 34, "HTTP 425", 35, 1)
Assert.eq(#scheduled, 1)
Assert.eq(scheduled[1].delay, 15)
scheduled[1].fn()
Assert.eq(#callbacks, 2)

callbacks[2](true, 35, nil, 35, 0)
Assert.is_true(job.done)
Assert.eq(job.result.cached, 35)
Assert.eq(job.result.total, 35)
Assert.eq(notices[#notices], "全本缓存完成：35 / 35 章")
