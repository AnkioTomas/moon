--[[--
进程内同步数据事件：核心发出，feature 订阅，核心不认识任何 feature。

订阅方是 `features/<name>/events.lua`，返回 `{ [事件名] = fn(...) }`，成功返回 true。
`Event.init()` 由 main.lua 在插件 init 时调用，经 `Features.scan` 扫描登记（按目录名排序，只登记一次）。
与 feature `init.lua` 里的 `events` 表无关：那是 KOReader 事件（首参 plugin、经 guard 隔离）。
`emit` 同步执行，订阅方抛错原样冒出；在调用方的事务里派发时，订阅方失败即可让调用方回滚。
init 之前 emit 没有订阅方（离线测试未 init 时只跑核心逻辑）。

已有事件：
- `book_identity_changed(source_id, old_stable_id, new_stable_id, merge)`：books 改名 / 收编，核心表迁完后发出

@module koplugin.book.utils.event
--]]

local Event = {}

---@type table<string, function[]>
local handlers = {}
local ready = false

--- 登记 feature 订阅方；FM / Reader 两个插件实例都会调，只登记一次。
function Event.init()
    if ready then return end
    ready = true
    for _idx, name in ipairs(require("features").scan("events")) do
        for event, fn in pairs(require("features." .. name .. ".events")) do
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
