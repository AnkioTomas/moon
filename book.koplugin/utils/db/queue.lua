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

local Queue = {}

local pending = {}
local running = false

local function flush()
    if running or #pending == 0 then
        return
    end
    running = true
    local item = table.remove(pending, 1)

    local ok, err = pcall(item.worker)
    running = false

    if not ok and item.on_failed then
        item.on_failed(err)
    elseif ok and item.on_done then
        item.on_done(nil)
    end

    if #pending > 0 then
        UIManager:nextTick(flush)
    end
end

--- 入队一个数据库操作；在主进程顺序执行，不堵 UI。
---@param worker fun() 数据库操作（在主进程执行）
---@param opts { on_done?: fun(raw: nil), on_failed?: fun(err: any) }|nil
function Queue.run(worker, opts)
    opts = opts or {}
    table.insert(pending, {
        worker = worker,
        on_done = opts.on_done,
        on_failed = opts.on_failed,
    })
    if not running then
        UIManager:nextTick(flush)
    end
end

--- 取消队列中所有待执行操作（不影响正在执行的）。
function Queue.clear()
    pending = {}
end

return Queue
