--[[-- 顶部状态栏独立设置页。 --]]

local Assert = require("support.assert")

local home = { home_topbar_items = {} }
local saves = 0

package.preload["gettext"] = function() return function(text) return text end end
package.preload["utils.settings"] = function()
    return {
        get = function() return home end,
        save = function(_, values)
            home = values
            saves = saves + 1
        end,
    }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end

local events = {}
local views = 0
local desktop = {
    onEvent = function(_, event)
        events[#events + 1] = event
    end,
    updateView = function()
        views = views + 1
    end,
}
local Settings = require("desktop.pages.setting.topbar")

local rows = Settings:rows(desktop)
Assert.len(rows, 8)
local memory = rows[3](600)
Assert.eq(memory.title, "剩余内存")
Assert.eq(memory.status, "开")
memory.callback()
Assert.is_false(home.home_topbar_items.memory)
Assert.eq(saves, 1)
Assert.eq(events[1], "topbar_changed")
Assert.len(events, 1)
Assert.eq(views, 1)

rows = Settings:rows(desktop)
Assert.eq(rows[3](600).status, "关")

return true
