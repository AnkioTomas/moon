--[[--
UI 线程延迟任务（不用 fork：HTTPS/SSL 状态被子进程继承会挂死）。

流程：先画 loading → 下一拍跑 task → cb 刷新。
返回 cancel()。

@module koplugin.book.moon.async
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local Async = {
    _tickets = {},
}

local function retain(ticket)
    Async._tickets[ticket] = true
end

local function release(ticket)
    Async._tickets[ticket] = nil
end

--- 当前帧结束后跑 task；cb(ok, result, err)
-- @param task fun(): any, string|nil
-- @param cb fun(ok: boolean, result: any, err: string|nil)
-- @param opts MoonAsyncOpts|nil
-- @return MoonAsyncCancel
function Async.run(task, cb, opts)
    local ticket = {
        cancelled = false,
        _work = nil,
    }
    local delay = opts and opts.delay

    local function work()
        release(ticket)
        if ticket.cancelled then
            return
        end
        local packed
        local ok, err = pcall(function()
            packed = table.pack(task())
        end)
        if ticket.cancelled then
            return
        end
        if not ok then
            logger.dbg("book.async task boom", err)
            cb(false, nil, tostring(err))
            return
        end
        cb(true, packed[1], packed[2])
    end

    ticket._work = work

    local function cancel()
        ticket.cancelled = true
        UIManager:unschedule(work)
        release(ticket)
    end

    ticket.cancel = cancel
    retain(ticket)
    if delay and delay > 0 then
        UIManager:scheduleIn(delay, work)
    else
        UIManager:nextTick(work)
    end
    return cancel
end

--- 取消单个 ticket
function Async.cancel(cancel_fn)
    if type(cancel_fn) == "function" then
        cancel_fn()
    end
end

--- 取消全部未完成任务
function Async.cancelAll()
    local list = {}
    for ticket in pairs(Async._tickets) do
        list[#list + 1] = ticket
    end
    logger.dbg("book.async cancelAll", #list)
    for i = 1, #list do
        local t = list[i]
        if t and t.cancel then
            t.cancel()
        end
    end
end

return Async
