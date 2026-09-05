--[[-- 顶部状态栏独立设置页。 --]]

local Assert = require("support.assert")

local home = { home_topbar_items = {} }
local saves = 0

package.preload["gettext"] = function() return function(text) return text end end
package.preload["utils.settings"] = function()
    return {
        get = function() return home end,
        saveSection = function(_, values)
            home = values
            saves = saves + 1
        end,
    }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end

local rebuilds = 0
local desktop = { rebuild = function() rebuilds = rebuilds + 1 end }
local Settings = require("ui.desktop.settings.topbar")

local rows = Settings.rows(desktop)
Assert.len(rows, 8)
local memory = rows[3](600)
Assert.eq(memory.title, "剩余内存")
Assert.eq(memory.status, "开")
memory.callback()
Assert.is_false(home.home_topbar_items.memory)
Assert.eq(saves, 1)
Assert.eq(rebuilds, 1)

rows = Settings.rows(desktop)
Assert.eq(rows[3](600).status, "关")

return true
