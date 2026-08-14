--[[--
UI 线程 Promise（不用 fork：HTTPS/SSL 状态被子进程继承会挂死）。

  Promise:new(function()
      return result, err   -- err ~= nil → fail；否则 next(result)
  end)
      :next(function(result) ... end)
      :fail(function(err) ... end)
      :cancel()

  -- 同步 worker 入口强制只能在 Promise:new(task) 里跑：
  Promise.requireAsync("Chapter.ensure")

@module koplugin.book.utils.promise
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

---@class MoonPromiseOpts
---@field delay number|nil 延迟启动秒数

--- UI 线程 Promise 实例
---@class MoonPromise
---@field new fun(self: MoonPromise, task: (fun(): any, any), opts: MoonPromiseOpts|nil): MoonPromise
---@field next fun(self: MoonPromise, fn: fun(result: any)): MoonPromise
---@field fail fun(self: MoonPromise, fn: fun(err: any)): MoonPromise
---@field cancel fun(self: MoonPromise)
---@field cancelAll fun()
---@field inAsync fun(): boolean
---@field requireAsync fun(who: string|nil)
local Promise = {}
Promise.__index = Promise

--- 未完成实例集合（供 cancelAll）
local _pending = {}

--- Promise:new(task) 执行深度；仅 task，不含 next/fail
local _task_depth = 0

--- 登记未完成 Promise
---@param p MoonPromise
local function retain(p)
    _pending[p] = true
end

--- 从未完成集合移除
---@param p MoonPromise
local function release(p)
    _pending[p] = nil
end

--- 当前是否在 Promise:new 的 task 回调栈内
---@return boolean
function Promise.inAsync()
    return _task_depth > 0
end

--- 强制异步：不在 task 内则 error（供同步 worker 入口调用）
---@param who string|nil 函数名，便于日志
function Promise.requireAsync(who)
    if _task_depth > 0 then
        return
    end
    who = (type(who) == "string" and who ~= "") and who or "?"
    error("book.promise: " .. who .. " must run inside Promise:new(task)", 2)
end

--- 置为 fulfilled，同步跑已注册的 next 回调
---@param p MoonPromise
---@param value any
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

--- 置为 rejected，同步跑已注册的 fail 回调
---@param p MoonPromise
---@param err any
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

--- 构造并调度 task；opts.delay > 0 则延时，否则 nextTick。
--- task 约定：`return result, err`；`err ~= nil` → fail，否则 next(result)。
---@param task fun(): any, any
---@param opts MoonPromiseOpts|nil
---@return MoonPromise
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

    --- 执行 task 并 settle；已非 pending 则跳过
    local function work()
        if o._state ~= "pending" then
            return
        end
        _task_depth = _task_depth + 1
        -- pcall 直接接住 task 的多返回：ok, result, err
        local ok, value, err = pcall(task)
        _task_depth = _task_depth - 1
        if o._state ~= "pending" then
            return
        end
        if not ok then
            logger.dbg("book.promise task boom", value)
            settle_fail(o, tostring(value))
            return
        end
        if err ~= nil then
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

--- 注册成功回调：next(result)。已 fulfilled 则下一拍补调。返回 self。
---@param fn fun(result: any)
---@return MoonPromise
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

--- 注册失败回调：fail(err)。已 rejected 则下一拍补调。返回 self。
---@param fn fun(err: any)
---@return MoonPromise
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

--- 取消本实例：不再回调 next/fail；已 settled 则无操作。
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

--- 取消全部未完成 Promise（模块函数，非实例方法）。
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
