--[[--
UI 线程 Promise（不用 fork：HTTPS/SSL 状态被子进程继承会挂死）。

  Promise:new(function()
      return result, err   -- err ~= nil → fail；否则 next(result)
  end)
      :next(function(result) ... end)
      :fail(function(err) ... end)
      :cancel()

@module koplugin.book.utils.promise
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

-- LuaJIT/5.1 无 table.pack
local function pack(...)
    return { n = select("#", ...), ... }
end

local Promise = {}
Promise.__index = Promise

local _pending = {}

local function retain(p)
    _pending[p] = true
end

local function release(p)
    _pending[p] = nil
end

local function settle_next(p, value)
    if p._state ~= "pending" then
        return
    end
    release(p)
    p._state = "fulfilled"
    p._value = value
    local list = p._on_next
    p._on_next = nil
    p._on_fail = nil
    for i = 1, #list do
        local ok, boom = pcall(list[i], value)
        if not ok then
            logger.warn("book.promise next boom", boom)
        end
    end
end

local function settle_fail(p, err)
    if p._state ~= "pending" then
        return
    end
    release(p)
    p._state = "rejected"
    p._err = err
    local list = p._on_fail
    p._on_next = nil
    p._on_fail = nil
    for i = 1, #list do
        local ok, boom = pcall(list[i], err)
        if not ok then
            logger.warn("book.promise fail boom", boom)
        end
    end
end

--- 构造并调度 task；opts.delay > 0 则延时
-- @param task fun(): any, any
-- @param opts MoonPromiseOpts|nil
-- @return MoonPromise
function Promise:new(task, opts)
    local o = setmetatable({
        _state = "pending",
        _value = nil,
        _err = nil,
        _on_next = {},
        _on_fail = {},
        _work = nil,
    }, Promise)

    local delay = opts and opts.delay

    local function work()
        if o._state ~= "pending" then
            return
        end
        local packed
        local ok, boom = pcall(function()
            packed = pack(task())
        end)
        if o._state ~= "pending" then
            return
        end
        if not ok then
            logger.dbg("book.promise task boom", boom)
            settle_fail(o, tostring(boom))
            return
        end
        local value = packed[1]
        local err = packed[2]
        if packed.n >= 2 and err ~= nil then
            settle_fail(o, err)
            return
        end
        settle_next(o, value)
    end

    o._work = work
    retain(o)
    if delay and delay > 0 then
        UIManager:scheduleIn(delay, work)
    else
        UIManager:nextTick(work)
    end
    return o
end

--- 成功：next(result)。已 settled 则下一拍补调。返回 self。
-- @param fn fun(result: any)
-- @return MoonPromise
function Promise:next(fn)
    if type(fn) ~= "function" then
        return self
    end
    if self._state == "fulfilled" then
        local value = self._value
        UIManager:nextTick(function()
            local ok, boom = pcall(fn, value)
            if not ok then
                logger.warn("book.promise next boom", boom)
            end
        end)
    elseif self._state == "pending" then
        self._on_next[#self._on_next + 1] = fn
    end
    return self
end

--- 失败：fail(err)。已 settled 则下一拍补调。返回 self。
-- @param fn fun(err: any)
-- @return MoonPromise
function Promise:fail(fn)
    if type(fn) ~= "function" then
        return self
    end
    if self._state == "rejected" then
        local err = self._err
        UIManager:nextTick(function()
            local ok, boom = pcall(fn, err)
            if not ok then
                logger.warn("book.promise fail boom", boom)
            end
        end)
    elseif self._state == "pending" then
        self._on_fail[#self._on_fail + 1] = fn
    end
    return self
end

--- 取消：不再回调 next/fail
function Promise:cancel()
    if self._state ~= "pending" then
        return
    end
    self._state = "cancelled"
    self._on_next = nil
    self._on_fail = nil
    release(self)
    if self._work then
        UIManager:unschedule(self._work)
        self._work = nil
    end
end

--- 取消全部未完成 Promise
function Promise.cancelAll()
    local list = {}
    for p in pairs(_pending) do
        list[#list + 1] = p
    end
    logger.dbg("book.promise cancelAll", #list)
    for i = 1, #list do
        list[i]:cancel()
    end
end

return Promise
