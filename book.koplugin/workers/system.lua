--[[--
Job 调度：FIFO 排队，按 Job.concurrency() 同时拉起 fork。

Job.run 只往这里丢任务。instant 不进调度。

@module koplugin.book.workers.system
--]]

local System = {}

local wait = {}
local running = 0

local function take()
    while wait[1] do
        local job = table.remove(wait, 1)
        if not job.settled and job.state == "queued" then
            return job
        end
    end
end

function System.pump()
    local Job = require("workers.job")
    local cap = Job.concurrency()
    while running < cap do
        local job = take()
        if not job then
            return
        end
        running = running + 1
        job:_start()
    end
end

--- 发布一个待 fork 的 Job。
---@param job table
function System.publish(job)
    wait[#wait + 1] = job
    System.pump()
end

--- 一个 fork 结束（成功/失败/取消），让出槽位。
function System.release()
    running = running - 1
    if running < 0 then
        running = 0
    end
    System.pump()
end

return System
