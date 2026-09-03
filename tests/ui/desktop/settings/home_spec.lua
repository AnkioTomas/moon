--[[-- 首页组件设置：至少保留一个组件，隐藏无关配置。 --]]

local Assert = require("support.assert")

local layout = { "recent_list" }
local home = {
    home_layout = layout,
    home_recent_list_mode = "hero_grid",
}
local saves = 0
local shown

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return {
        template = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end,
    }
end
package.preload["utils.settings"] = function()
    return {
        get = function() return home end,
        saveSection = function(_, values)
            home = values
            layout = values.home_layout
            saves = saves + 1
        end,
    }
end
package.preload["ui.desktop.home.components.base"] = function()
    local components = {
        { id = "recent_list", label = "最近阅读列表", icon = "view_list" },
        { id = "clock", label = "时钟", icon = "schedule" },
    }
    return {
        components = components,
        enabledLayout = function() return layout end,
        find = function(id)
            for _, component in ipairs(components) do
                if component.id == id then return component end
            end
        end,
    }
end
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown = widget end,
        close = function() end,
    }
end
package.preload["ui.components.popup"] = function()
    return { list = function(opts) shown = opts end }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
package.preload["ui.desktop.home"] = function()
    return { invalidate = function() end }
end

local Settings = require("ui.desktop.settings.home")
local desktop = { rebuild = function() end }

local sections = Settings.sections(desktop)
Assert.len(sections[1].rows, 2)
local enabled_row = sections[2].rows[1](600)
enabled_row.callback()
local toggle = shown.buttons[1][1]
Assert.is_false(toggle.enabled)
toggle.callback()
Assert.eq(saves, 0)
Assert.eq(layout[1], "recent_list")

layout = { "clock" }
home.home_layout = layout
sections = Settings.sections(desktop)
Assert.len(sections[1].rows, 1)

return true
