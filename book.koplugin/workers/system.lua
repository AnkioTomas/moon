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
        if not job.settled then
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

--- 同时允许的 fork 数：先给主进程留 48MB 余量，其余每 32MB 一个槽，夹在 1～8。
--- 每个子进程都带着阅读器的页表和各自的解析缓冲，256MB 设备上并发太多会触发 OOM killer 杀掉 KOReader。
--- 读不到 /proc/meminfo 按 4。
---@return number
function System:concurrency()
    local mem = self:memAvailableMB()
    if not mem then
        return 4
    end
    return math.max(1, math.min(8, math.floor((mem - 48) / 32)))
end

return System
