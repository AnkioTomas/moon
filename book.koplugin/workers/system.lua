--[[--
Job 调度：FIFO 排队，按 concurrency 同时拉起 fork。

不是 class。全世界一份队列。Job.run 只往这里丢任务。instant 不进调度。

@module koplugin.book.workers.system
--]]

local System = {
    wait = {},
    running = 0,
}

function System:take()
    while self.wait[1] do
        local job = table.remove(self.wait, 1)
        if not job.settled and job.state == "queued" then
            return job
        end
    end
end

function System:pump()
    local cap = self:concurrency()
    while self.running < cap do
        local job = self:take()
        if not job then
            return
        end
        self.running = self.running + 1
        job:_start()
    end
end

--- 发布一个待 fork 的 Job。
---@param job table
function System:publish(job)
    self.wait[#self.wait + 1] = job
    self:pump()
end

--- 一个 fork 结束（成功/失败/取消），让出槽位。
function System:release()
    self.running = self.running - 1
    if self.running < 0 then
        self.running = 0
    end
    self:pump()
end

---@return number|nil MB
function System:memAvailableMB()
    local f = io.open("/proc/meminfo", "r")
    if not f then
        return nil
    end
    local avail, free
    for line in f:lines() do
        local key, kb = line:match("^(%w+):%s*(%d+)")
        if key == "MemAvailable" then
            avail = tonumber(kb)
        elseif key == "MemFree" then
            free = tonumber(kb)
        end
    end
    f:close()
    local kb = avail or free
    return kb and (kb / 1024) or nil
end

--- 同时允许的 fork 数：每 32MB 可用内存一个槽，夹在 1～20。
--- 读不到 /proc/meminfo 按 4。
---@return number
function System:concurrency()
    local mem = self:memAvailableMB()
    if not mem then
        return 4
    end
    local slots = math.floor(mem / 32)
    if slots < 1 then
        return 1
    end
    if slots > 20 then
        return 20
    end
    return slots
end

return System
