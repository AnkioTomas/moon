--[[-- features.panel.actions.desktop.screenshot 离线用例。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

---@type integer, integer, integer, { delay: number, fn: function }|nil
local repainted, waited, sent, scheduled = 0, 0, 0, nil
package.preload["ui/uimanager"] = function()
    return {
        forceRePaint = function() repainted = repainted + 1 end,
        waitForVSync = function() waited = waited + 1 end,
        sendEvent = function() sent = sent + 1 end,
        scheduleIn = function(_self, delay, fn) scheduled = { delay = delay, fn = fn } end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(name) return { name = name } end }
end
package.preload["device"] = function()
    return { hasEinkScreen = function() return true end }
end

local Action = require("features.panel.actions.desktop.screenshot")
Assert.eq(Action.id, "screenshot")
Assert.eq(Action.title, "截屏")
Assert.eq(Action.scope, "desktop")
Assert.eq(Action.icon, "photo_camera")

Action.run({})
Assert.eq(repainted, 1)
Assert.eq(waited, 1)
Assert.eq(sent, 1)

-- 长按：先提示，延时后才截屏。
local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_self, o) toasts[#toasts + 1] = o; return { show = function() end } end }
end
Action.hold({})
Assert.eq(#toasts, 1)
Assert.eq(sent, 1, "延时到之前不截屏")
Assert.eq(scheduled.delay, 3)
scheduled.fn()
Assert.eq(sent, 2)
