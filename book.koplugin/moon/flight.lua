--[[--
单飞 + 多 waiter。

同 key 只跑一次异步任务；多个订阅者共用结果。
失败不扇出（waiter 保留，可被下次 run 命中）；abortAll 清空。

  local unwatch = Flight.watch(key, function(result) ... end)
  Flight.run(key, function() return result, err end)
  Flight.resolve(key, result)  -- 缓存命中等同步完成
  unwatch()
  Flight.abortAll()

@module koplugin.book.moon.flight
--]]

local Async = require("moon.async")

local Flight = {
    _inflight = {},
    _waiters = {},
    _cancels = {},
}

local function dropCancel(cancel)
    for i = #Flight._cancels, 1, -1 do
        if Flight._cancels[i] == cancel then
            table.remove(Flight._cancels, i)
        end
    end
end

--- 订阅 key 的完成结果；返回 unwatch()
-- @param key string
-- @param fn fun(result: any)
-- @return function
function Flight.watch(key, fn)
    if type(key) ~= "string" or key == "" or type(fn) ~= "function" then
        return function() end
    end
    local q = Flight._waiters[key]
    if not q then
        q = {}
        Flight._waiters[key] = q
    end
    q[#q + 1] = fn
    local alive = true
    return function()
        if not alive then
            return
        end
        alive = false
        local cur = Flight._waiters[key]
        if not cur then
            return
        end
        for i = #cur, 1, -1 do
            if cur[i] == fn then
                table.remove(cur, i)
            end
        end
        if #cur == 0 then
            Flight._waiters[key] = nil
        end
    end
end

--- 成功扇出并清除该 key 的 waiters
-- @param key string
-- @param result any
function Flight.resolve(key, result)
    local q = Flight._waiters[key]
    Flight._waiters[key] = nil
    if not q then
        return
    end
    for i = 1, #q do
        pcall(q[i], result)
    end
end

--- 同 key 单飞；task 返回 (result, err)，result ~= nil 才 resolve
-- @param key string
-- @param task fun(): any, string|nil
function Flight.run(key, task)
    if type(key) ~= "string" or key == "" or type(task) ~= "function" then
        return
    end
    if Flight._inflight[key] then
        return
    end
    Flight._inflight[key] = true

    local async_cancel
    local function cancel()
        Flight._inflight[key] = nil
        dropCancel(cancel)
        Async.cancel(async_cancel)
    end

    async_cancel = Async.run(task, function(ok, result)
        Flight._inflight[key] = nil
        dropCancel(cancel)
        -- 失败不 resolve：waiter 保留，可被下次 run 命中
        if ok and result ~= nil then
            Flight.resolve(key, result)
        end
    end)
    Flight._cancels[#Flight._cancels + 1] = cancel
end

--- 取消全部在飞任务并丢弃 waiters
function Flight.abortAll()
    local list = Flight._cancels
    Flight._cancels = {}
    Flight._inflight = {}
    Flight._waiters = {}
    for i = 1, #list do
        list[i]()
    end
end

return Flight
