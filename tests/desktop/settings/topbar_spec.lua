--[[-- 顶部状态栏独立设置页：每个顶栏项（含 feature 的项）一行开关。 --]]

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

package.preload["desktop.topbar"] = function()
    return {
        items = function()
            return {
                { id = "clock", label = "时钟", icon = "schedule" },
                { id = "source", label = "数据源", icon = "source" },
                { id = "memory", label = "剩余内存", icon = "memory" },
                { id = "bluetooth", label = "蓝牙", icon = "bluetooth" },
            }
        end,
    }
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
Assert.len(rows, 4)
Assert.eq(rows[4](600).title, "蓝牙")
Assert.is_true(rows[4](600).toggle, "不在配置里的项按开处理")
local memory = rows[3](600)
Assert.eq(memory.title, "剩余内存")
Assert.is_true(memory.toggle)
memory.callback()
Assert.is_false(home.home_topbar_items.memory)
Assert.eq(saves, 1)
Assert.eq(events[1], "topbar_changed")
Assert.len(events, 1)
Assert.eq(views, 1)

rows = Settings:rows(desktop)
Assert.is_false(rows[3](600).toggle)

return true
