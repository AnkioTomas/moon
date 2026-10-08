--[[--
utils.event：init 按 Features.scan 的顺序登记 events.lua；emit 同步派发，任一订阅方失败即停；
init 只登记一次；未 init 时没有订阅方。

@module tests.utils.event_spec
--]]

local Assert = require("support.assert")

local scans = 0
package.preload["features"] = function()
    return {
        scan = function(file)
            assert(file == "events")
            scans = scans + 1
            return { "a", "b" }
        end,
    }
end

local seen = {}
package.preload["features.a.events"] = function()
    return {
        e = function(x, y)
            seen[#seen + 1] = "a:" .. x .. y
            return true
        end,
        stop = function()
            seen[#seen + 1] = "a"
            return false
        end,
        throw = function() error("listener boom") end,
    }
end
package.preload["features.b.events"] = function()
    return {
        e = function(x, y)
            seen[#seen + 1] = "b:" .. x .. y
            return true
        end,
        stop = function()
            seen[#seen + 1] = "b"
            return true
        end,
    }
end

package.loaded["utils.event"] = nil
local Event = require("utils.event")

-- 未 init：没有订阅方，视为成功
Assert.is_true(Event.emit("e", "x", "y"))
Assert.len(seen, 0)

Event.init()
Event.init() -- FM / Reader 两个实例都会调，只登记一次
Assert.eq(scans, 1)

-- 按扫描顺序派发并透传参数
Assert.is_true(Event.emit("e", "x", "y"))
Assert.eq(table.concat(seen, ","), "a:xy,b:xy")

-- 没有订阅方的事件视为成功
Assert.is_true(Event.emit("nobody"))

-- 任一订阅方返回假值：emit 返回 false，后面的不再执行
seen = {}
Assert.is_false(Event.emit("stop"))
Assert.eq(table.concat(seen, ","), "a")

-- 订阅方抛错原样冒出
Assert.errors(function() Event.emit("throw") end, "listener boom")

package.loaded["utils.event"] = nil
