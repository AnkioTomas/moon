--[[-- 快捷动作执行：关面板的动作不再刷新已关闭的菜单；只带 event 的阅读动作也能执行。 --]]
---@diagnostic disable: missing-fields, assign-type-mismatch

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local events, ticks, scheduled = {}, 0, {}
package.preload["ui/event"] = function()
    return { new = function(_self, name) return { name = name } end }
end
package.preload["ui/uimanager"] = function()
    return {
        broadcastEvent = function(_self, ev) events[#events + 1] = ev.name end,
        nextTick = function(_self, fn) ticks = ticks + 1; fn() end,
        scheduleIn = function(_self, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
    }
end
local Registry = require("features.panel.actions.registry")

local function opts()
    local o = { closed = 0, refreshed = 0 }
    o.close = function() o.closed = o.closed + 1 end
    o.refresh = function() o.refreshed = o.refreshed + 1 end
    return o
end

-- 关面板的动作：关一次，不刷新。
local o = opts()
Registry.execute({ id = "rotate", event = "IterateRotation" }, { ui = nil }, o)
Assert.eq(o.closed, 1)
Assert.eq(o.refreshed, 0, "已关闭的菜单不能再 updateItems")
Assert.eq(ticks, 0)
Assert.eq(events[1], "IterateRotation")

-- keep_open：不关，下一 tick 刷新。
o = opts()
Registry.execute({ id = "night", event = "ToggleNightMode", keep_open = true }, { ui = nil }, o)
Assert.eq(o.closed, 0)
Assert.eq(o.refreshed, 1)

-- refresh_delay：延迟刷新。
o = opts()
Registry.execute({ id = "wifi", event = "ToggleWifi", keep_open = true, refresh_delay = 1 }, { ui = nil }, o)
Assert.eq(o.refreshed, 0)
Assert.eq(scheduled[1].delay, 1)

-- 阅读动作：run 拿到 ctx；只带 event 的走广播，不再因 action.run 为 nil 崩溃。
local ctx_seen
Registry.execute({ id = "x", run = function(ctx) ctx_seen = ctx end }, { ui = "reader" }, nil)
Assert.eq(ctx_seen.ui, "reader")
Registry.execute({ id = "y", event = "ReaderEvent" }, { ui = "reader" }, opts())
Assert.eq(events[#events], "ReaderEvent")

-- available / active 不再吞异常：抛错要冒到入口 guard。
Assert.errors(function()
    Registry.available({ id = "bad", available = function() error("boom") end })
end, "boom")
Assert.is_false(Registry.available(nil))
Assert.is_false(Registry.active({ id = "plain" }))
Assert.is_true(Registry.active({ id = "on", active = function() return true end }))
