--[[-- 桌面生命周期：阶段方法自己做事，不经过转发器。 --]]

local Assert = require("support.assert")

local unschedules = 0
local scheduled = 0
local closed = {}
local ticks = {}

local function emptyModule() return {} end
for _, name in ipairs({
    "ui/bidi",
    "ffi/blitbuffer",
    "ui/widget/container/framecontainer",
    "ui/geometry",
    "ui/gesturerange",
    "ui/widget/overlapgroup",
    "utils.perf",
    "ui.desktop.library",
    "ui.desktop.store",
    "ui.desktop.insight",
    "ui.desktop.settings",
    "ui.desktop.detail",
    "ui.panel.native",
    "ui.components.image",
    "ui.views.topbar",
    "ui.desktop.settings.source",
    "ui.views.bottombar",
    "ui.components.bookui",
    "book.store",
    "source.cache_queue",
}) do
    package.preload[name] = emptyModule
end
package.preload["utils.log"] = function()
    return {
        dbg = function() end,
        info = function() end,
        warn = function() end,
        err = function() end,
        flush = function() end,
    }
end
package.preload["device"] = function() return { screen = {} } end
package.preload["gettext"] = function()
    return function(text) return text end
end
package.preload["ui/widget/container/inputcontainer"] = function()
    return {
        extend = function(_, value) return value end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, fn) ticks[#ticks + 1] = fn end,
        scheduleIn = function(_, _, fn)
            scheduled = scheduled + 1
            return fn
        end,
        unschedule = function()
            unschedules = unschedules + 1
        end,
        close = function(_, widget) closed[#closed + 1] = widget end,
        setDirty = function() end,
        show = function() end,
    }
end
package.preload["ui.desktop.home"] = function()
    return { new = function() return {} end }
end

package.loaded["ui.desktop"] = nil
local Desktop = require("ui.desktop")

local log = {}
local function child(name, methods)
    local c = { name = name }
    for _, method in ipairs(methods) do
        c[method] = function(self)
            log[#log + 1] = self.name .. "." .. method
        end
    end
    return c
end

local desk = {
    tab = "library",
    home = child("home", { "onResume", "onPause", "onDestroy", "onCancel" }),
    library = child("library", { "onResume", "onPause", "onCancel", "onDestroy" }),
    store = child("store", { "onPause", "onCancel", "onDestroy" }),
    insight = child("insight", { "onPause", "onCancel", "onDestroy" }),
    settings = child("settings", { "onPause", "onDestroy" }),
    bottombar = child("bottombar", { "onPause", "onDestroy" }),
    detail = child("detail", { "onCancel" }),
    topbar = child("topbar", { "onResume", "onPause", "onDestroy" }),
    _books_sync_cancel = { cancel = function() log[#log + 1] = "books.cancel" end },
    plugin = {
        emitToSource = function(_, event)
            log[#log + 1] = event
        end,
    },
}
for _, name in ipairs({ "onResume", "onPause", "onCancel", "onDestroy" }) do
    desk[name] = Desktop[name]
end

desk.lifecycle = require("ui.lifecycle").attach(desk)

log = {}
desk:onPause()
Assert.eq(table.concat(log, ","),
    "topbar.onPause,bottombar.onPause,home.onPause,library.onPause,store.onPause,insight.onPause,settings.onPause")

log = {}
desk:onResume()
Assert.eq(table.concat(log, ","), "topbar.onResume,library.onResume")
Assert.is_true(desk.lifecycle:uiReady())

desk.tab = "home"
log = {}
desk:onResume()
Assert.eq(table.concat(log, ","), "topbar.onResume,home.onResume")

desk.plugin.desktop = desk
log = {}
desk:onDestroy()
Assert.eq(desk.lifecycle.state, "Destroy")
Assert.is_nil(desk.plugin.desktop)
Assert.eq(table.concat(log, ","),
    "topbar.onPause,bottombar.onPause,home.onPause,library.onPause,store.onPause,insight.onPause,settings.onPause,topbar.onDestroy,bottombar.onDestroy,home.onDestroy,library.onDestroy,store.onDestroy,insight.onDestroy,settings.onDestroy")

log = {}
desk:onDestroy()
Assert.eq(#log, 0)
Assert.eq(desk.lifecycle.state, "Destroy")

local payload = {}
local received = {}
local events = setmetatable({
    lifecycle = { state = "Resume" },
    topbar = { onEvent = function(_, event, data)
        received[#received + 1] = event
        Assert.eq(data, payload)
    end },
    home = { onEvent = function(_, event, data)
        received[#received + 1] = event
        Assert.eq(data, payload)
    end },
}, { __index = Desktop })
events:onEvent("Changed", payload)
Assert.eq(table.concat(received, ","), "Changed,Changed")
events.lifecycle.state = "Destroy"
events:onEvent("Changed", payload)
Assert.eq(#received, 2)

local ko_events = {}
local ko = setmetatable({
    lifecycle = { state = "Resume" },
    topbar = { onEvent = function(_, event)
        ko_events[#ko_events + 1] = event
    end },
}, { __index = Desktop })
ko:onCharging()
ko:onNetworkConnected()
ko:onFrontlightStateChanged()
Assert.eq(table.concat(ko_events, ","), "Charging,NetworkConnected,FrontlightStateChanged")

return true
