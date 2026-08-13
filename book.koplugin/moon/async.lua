--[[
  Deferred background work for UI.

  KOReader fork-subprocess + HTTPS often hangs (SSL state inherited by child),
  so the UI stuck on "loading" forever. We schedule work on the next UI tick:
  1) caller paints loading / rebuilds
  2) UIManager paints
  3) task runs (may block briefly on network)
  4) callback rebuilds with real data

  Returns a cancel() function.
]]

local UIManager = require("ui/uimanager")

local Async = {
    _tickets = {},
}

local function retain(ticket)
    Async._tickets[ticket] = true
end

local function release(ticket)
    Async._tickets[ticket] = nil
end

--- Run task after the current UI frame; invoke cb(ok, result, err).
-- task may return (result, err). Returns cancel().
---@param task fun(): any, string|nil
---@param cb fun(ok: boolean, result: any, err: string|nil)
---@param opts MoonAsyncOpts|nil
---@return MoonAsyncCancel
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

---@param cancel_fn MoonAsyncCancel|nil
function Async.cancel(cancel_fn)
    if type(cancel_fn) == "function" then
        cancel_fn()
    end
end

function Async.cancelAll()
    local list = {}
    for ticket in pairs(Async._tickets) do
        list[#list + 1] = ticket
    end
    for i = 1, #list do
        local t = list[i]
        if t and t.cancel then
            t.cancel()
        end
    end
end

return Async
