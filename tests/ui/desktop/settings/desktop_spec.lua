--[[-- 桌面设置入口。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
package.preload["host"] = function()
    return { OPEN_ON_START_ID = "book" }
end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = { saveSetting = function() end }

local shown_sub, shown_parent
local desktop = {
    updateView = function() end,
    settings = {
        showSub = function(_, sub, parent)
            shown_sub, shown_parent = sub, parent
        end,
    },
}

local Settings = require("ui.desktop.settings.desktop")
local rows = Settings.new():rows(desktop, false)
Assert.len(rows, 2)
Assert.eq(rows[1](600).title, "首页顶栏")
Assert.eq(rows[2](600).title, "启动打开桌面")

rows[1](600).callback()
Assert.eq(shown_sub, "topbar")
Assert.eq(shown_parent, "appearance")

_G.G_reader_settings = previous_settings

return true
