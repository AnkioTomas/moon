--[[--
进程内同步数据事件：核心发出，feature 订阅，核心不认识任何 feature。

订阅方是 `features/<name>/events.lua`，返回 `{ [事件名] = fn(...) }`，成功返回 true。
`Event.init(listeners)` 由 main.lua 在插件 init 时调用，传入 `Features.listeners("events")`（按目录名排序，只登记一次）。
与 feature `init.lua` 里的 `events` 表无关：那是 KOReader 事件（首参 plugin、经 guard 隔离）。
`emit` 同步执行，订阅方抛错原样冒出；在调用方的事务里派发时，订阅方失败即可让调用方回滚。
init 之前 emit 没有订阅方（离线测试未 init 时只跑核心逻辑）。

已有事件：
- `book_identity_changed(source_id, old_stable_id, new_stable_id, merge)`：books 改名 / 收编，核心表迁完后发出
- `book_removed(source_id, stable_id)`：远端确认删除、撕墓碑，核心表清完后发出

@module koplugin.book.utils.event
--]]

local Event = {}

---@type table<string, function[]>
local handlers = {}
local ready = false

--- 登记订阅方（由 main 传入各 feature 的 events 表，utils 不反向依赖 features）；
--- FM / Reader 两个插件实例都会调，只登记一次。
---@param listeners table<string, function>[] 按派发顺序
function Event.init(listeners)
    if ready then return end
    ready = true
    for _idx, map in ipairs(listeners) do
        for event, fn in pairs(map) do
            handlers[event] = handlers[event] or {}
            table.insert(handlers[event], fn)
        end
    end
end

--- 同步派发事件；任一订阅方返回假值立即停止并返回 false。
---@param event string
---@return boolean
function Event.emit(event, ...)
    for _idx, fn in ipairs(handlers[event] or {}) do
        if not fn(...) then return false end
    end
    return true
end

return Event
