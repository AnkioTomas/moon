--[[-- 桌面设置入口。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
package.preload["host"] = function()
    return { OPEN_ON_START_ID = "book" }
end
local book_settings = { drawer_opens_desktop = true }
package.preload["utils.settings"] = function()
    return {
        get = function() return book_settings end,
        save = function(values)
            for key, value in pairs(values) do book_settings[key] = value end
        end,
    }
end

local previous_settings = _G.G_reader_settings
local saved
_G.G_reader_settings = { saveSetting = function(_, key, value) saved = { key, value } end }

local desktop = { updateView = function() end }
local Settings = require("ui.desktop.settings.desktop")
local rows = Settings:rows(desktop, false)
Assert.len(rows, 2)
Assert.eq(rows[1](600).title, "启动打开桌面")
Assert.eq(rows[1](600).kind, "toggle")

rows[1](600).callback()
Assert.eq(saved[1], "start_with")
Assert.eq(saved[2], "book")

local drawer = rows[2](600)
Assert.eq(drawer.title, "抽屉图标打开桌面")
Assert.is_true(drawer.status_on)
drawer.callback()
Assert.eq(book_settings.drawer_opens_desktop, false)
Assert.is_false(rows[2](600).status_on)

_G.G_reader_settings = previous_settings

return true
