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

local shown_sub, shown_parent
local desktop = {
    rebuild = function() end,
    showSettingsSub = function(_, sub, parent)
        shown_sub, shown_parent = sub, parent
    end,
}

local Settings = require("ui.desktop.settings.desktop")
local rows = Settings.rows(desktop, false)
Assert.len(rows, 3)
Assert.eq(rows[1](600).title, "首页组件")
Assert.eq(rows[2](600).title, "首页顶栏")
Assert.eq(rows[3](600).title, "启动打开桌面")

local function rowByTitle(title)
    for _, build in ipairs(rows) do
        local row = build(600)
        if row.title == title then return row end
    end
end

rowByTitle("首页组件").callback()
Assert.eq(shown_sub, "home")
Assert.eq(shown_parent, "appearance")

rowByTitle("首页顶栏").callback()
Assert.eq(shown_sub, "topbar")
Assert.eq(shown_parent, "appearance")

_G.G_reader_settings = previous_settings

return true
