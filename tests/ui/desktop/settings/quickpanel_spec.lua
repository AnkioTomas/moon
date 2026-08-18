--[[-- 快捷面板设置项离线用例。
@module tests.ui.desktop.settings.quickpanel_spec
--]]

local Assert = require("support.assert")

package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, value) return value end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end }
end
package.preload["ui.components.popup"] = function()
    return { list = function() end }
end

local built
package.preload["ui.components.settingrow"] = function()
    return {
        build = function(_width, value)
            built = value
            return value
        end,
    }
end
package.preload["ui.desktop.panel"] = function()
    return {
        options = function()
            return {{
                id = "plugin.example.popup",
                title = "插件页面",
                icon = "extension",
                enabled = true,
                position = 1,
                available = false,
            }}
        end,
        iconChoices = function() return { "extension", "settings" } end,
        enabledCount = function() return 1 end,
        setEnabled = function() end,
        setIcon = function() end,
        move = function() end,
    }
end
package.preload["gettext"] = function()
    return function(value) return value end
end
package.preload["ffi/util"] = function()
    return { template = function(value, position) return value:gsub("%%1", tostring(position)) end }
end

local QuickPanel = require("ui.desktop.settings.quickpanel")
local desktop = { rebuild = function() end }
local rows = QuickPanel.rows(desktop)

Assert.len(rows, 1)
rows[1](400)
Assert.eq(built.title, "插件页面")
Assert.eq(built.status, "当前设备不可用")
Assert.is_true(built.chevron)
Assert.is_true(type(built.callback) == "function")
