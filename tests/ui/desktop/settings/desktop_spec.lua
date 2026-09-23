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
local saved
_G.G_reader_settings = { saveSetting = function(_, key, value) saved = { key, value } end }

local desktop = { updateView = function() end }
local Settings = require("ui.desktop.settings.desktop")
local rows = Settings.new():rows(desktop, false)
Assert.len(rows, 1)
Assert.eq(rows[1](600).title, "启动打开桌面")
Assert.eq(rows[1](600).kind, "toggle")

rows[1](600).callback()
Assert.eq(saved[1], "start_with")
Assert.eq(saved[2], "book")

_G.G_reader_settings = previous_settings

return true
