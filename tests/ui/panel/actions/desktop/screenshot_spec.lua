--[[-- ui.panel.actions.desktop.screenshot 离线用例。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

local repainted, waited, sent = 0, 0, 0
package.preload["ui/uimanager"] = function()
    return {
        forceRePaint = function() repainted = repainted + 1 end,
        waitForVSync = function() waited = waited + 1 end,
        sendEvent = function() sent = sent + 1 end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(name) return { name = name } end }
end
package.preload["device"] = function()
    return { hasEinkScreen = function() return true end }
end

local Action = require("ui.panel.actions.desktop.screenshot")
Assert.eq(Action.id, "screenshot")
Assert.eq(Action.title, "截屏")
Assert.eq(Action.scope, "desktop")
Assert.eq(Action.icon, "photo_camera")

Action.run({})
Assert.eq(repainted, 1)
Assert.eq(waited, 1)
Assert.eq(sent, 1)
