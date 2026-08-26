--[[-- action_list 与 desktop 配置持久化离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/event"] = function() return { new = function() return {} end } end
package.preload["ui/uimanager"] = function()
    return { broadcastEvent = function() end, nextTick = function() end, scheduleIn = function() end }
end
package.preload["device"] = function()
    return {
        getPowerDevice = function()
            return {
                fl_min = 0, fl_max = 100,
                frontlightIntensity = function() return 50 end,
                frontlightWarmth = function() return 50 end,
            }
        end,
    }
end

local saved = {}
package.preload["utils.settings"] = function()
    return {
        get = function() return saved end,
        save = function(values) saved = values end,
    }
end

local ACTIONS = {
    night = { id = "night", title = "夜间", icon = "dark_mode", scope = "desktop", event = "ToggleNightMode" },
    wifi = { id = "wifi", title = "Wi-Fi", icon = "wifi", scope = "desktop", event = "ToggleWifi", available = function() return false end },
    rotate = { id = "rotate", title = "旋转", icon = "rotate", scope = "desktop", event = "IterateRotation" },
}
local ORDER = { "night", "wifi", "rotate" }

package.preload["ui.panel.actions.registry"] = function()
    local Registry = {}
    function Registry.get(id) return ACTIONS[id] end
    function Registry.desktopOrder() return ORDER end
    function Registry.available(action, _ctx)
        if not action or not action.available then return true end
        return action.available() == true
    end
    function Registry.active() return false end
    return Registry
end

package.loaded["ui.panel.desktop"] = nil
local DesktopPanel = require("ui.panel.desktop")

Assert.eq(DesktopPanel.enabledCount(), 2)

DesktopPanel.setEnabled("wifi", true)
Assert.eq(DesktopPanel.enabledCount(), 2)

DesktopPanel.setEnabled("rotate", true)
Assert.eq(DesktopPanel.enabledCount(), 3)
Assert.eq(saved.quick_panel_actions[3], "rotate")

saved.quick_panel_actions = { "night", "wifi", "wifi", "unknown", "rotate" }
Assert.eq(DesktopPanel.enabledCount(), 3)
DesktopPanel.setEnabled("night", true)
Assert.eq(#saved.quick_panel_actions, 3)
Assert.eq(saved.quick_panel_actions[1], "night")
Assert.eq(saved.quick_panel_actions[2], "wifi")
Assert.eq(saved.quick_panel_actions[3], "rotate")

DesktopPanel.move("rotate", -1)
Assert.eq(saved.quick_panel_actions[1], "night")
Assert.eq(saved.quick_panel_actions[2], "rotate")
Assert.eq(saved.quick_panel_actions[3], "wifi")

local function findOption(id)
    for _, option in ipairs(DesktopPanel.options()) do
        if option.id == id then return option end
    end
end
Assert.is_false(findOption("wifi").available)
