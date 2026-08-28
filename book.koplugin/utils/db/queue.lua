--[[--
数据库操作串行队列：主进程单连接顺序执行，不堵 UI。

所有数据库写/读操作经此队列排队，避免多子进程并发访问 SQLite。

  local DbQueue = require("utils.db.queue")

  DbQueue.run(function()
      local BookDB = require("utils.db.book")
      BookDB.upsert({ ... })
  end)

@module koplugin.book.utils.db.queue
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local Queue = {}

local pending = {}
local pending_head = 1
local pending_tail = 0
local running = false

--- 取队首任务同步执行一次，还有剩余就排下一 tick 继续。
--- 一次只跑一个任务（每 tick 一个），保证 SQLite 单连接串行访问且不长时间占住 UI。
--- worker 抛错走 on_failed，回调自身抛错只记日志，都不会中断队列。
local function flush()
    if running or pending_head > pending_tail then
        return
    end
    running = true
    local item = pending[pending_head]
    pending[pending_head] = nil
    pending_head = pending_head + 1

    local ok, err = pcall(item.worker)
    running = false

    -- 回调自身抛错不能卡死队列：隔离之，剩余任务照常调度
    local cb = ok and item.on_done or item.on_failed
    if cb then
        local cb_ok, cb_err = pcall(cb, ok and nil or err)
        if not cb_ok then
            logger.warn("book.db queue callback failed", cb_err)
        end
    end

    if pending_head <= pending_tail then
        UIManager:nextTick(flush)
    else
        pending = {}
        pending_head = 1
        pending_tail = 0
    end
end

--- 入队一个数据库操作；在主进程顺序执行，不堵 UI。
---@param worker fun() 数据库操作（在主进程执行）
---@param opts { on_done?: fun(raw: nil), on_failed?: fun(err: any) }|nil
function Queue.run(worker, opts)
    opts = opts or {}
    pending_tail = pending_tail + 1
    pending[pending_tail] = {
        worker = worker,
        on_done = opts.on_done,
        on_failed = opts.on_failed,
    }
    if not running then
        UIManager:nextTick(flush)
    end
end

--- 取消队列中所有待执行操作（不影响正在执行的）。
function Queue.clear()
    pending = {}
    pending_head = 1
    pending_tail = 0
end

return Queue
