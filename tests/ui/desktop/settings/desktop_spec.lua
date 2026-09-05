--[[-- 桌面设置入口。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return {
        template = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end,
    }
end
package.preload["ui.desktop.home.components.base"] = function()
    return { enabledLayout = function() return { "recent_hero", "recent_list" } end }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
package.preload["host"] = function()
    return { OPEN_ON_START_ID = "book" }
end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = { saveSetting = function() end }

local shown_sub
local desktop = {
    rebuild = function() end,
    showSettingsSub = function(_, sub) shown_sub = sub end,
}

local Settings = require("ui.desktop.settings.desktop")
local rows = Settings.rows(desktop, false)
Assert.len(rows, 2)

rows[2](600).callback()
Assert.eq(shown_sub, "home")

_G.G_reader_settings = previous_settings

return true
