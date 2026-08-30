--[[--
一次性 Job 的子进程上下文。

不保存主进程对象；唯一职责是标记 fork 子进程并向主进程发送进度数据。

@module koplugin.book.workers.context
--]]

local Context = {}
local writer

---@alias WorkerProgress table
---@alias WorkerSender fun(message: WorkerMessage): boolean, string|nil

---@class WorkerContext
---@field post fun(message: WorkerProgress)
---@field inSubProcess fun(): boolean

---@return boolean
function Context.inSubProcess()
    return writer ~= nil
end

---@param send WorkerSender
---@return nil
function Context.enter(send)
    writer = send
end

---@return nil
function Context.leave()
    writer = nil
end

---@param message WorkerProgress
---@return nil
function Context.post(message)
    if not writer then error("workers.context.post: only available in a job", 2) end
    local ok, err = writer({ type = "progress", value = message })
    if not ok then error("workers.context.post: " .. tostring(err), 2) end
end

return Context
