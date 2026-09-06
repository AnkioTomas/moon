--[[-- 阅读设置摘要与划词菜单详情分离。 --]]

local Assert = require("support.assert")

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
        get = function() return {} end,
        saveSection = function() end,
    }
end
package.preload["ui.components.settingrow"] = function()
    return { build = function(_, opts) return opts end }
end
package.preload["ui.reader.bars"] = function()
    return {
        topBarPreference = function() return true end,
        bottomBarPreference = function() return true end,
    }
end
package.preload["patch.page_turn_animation"] = function()
    return { isEnabled = function() return false end }
end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/uimanager"] = function() return {} end

local Settings = require("ui.desktop.settings.reader")
local desktop = {}

local sections = Settings.sections(desktop)
local reading
for _, section in ipairs(sections) do
    Assert.is_true(section.title ~= "阅读弹窗")
    if section.title == "阅读界面" then reading = section end
end
Assert.is_true(reading ~= nil)
Assert.eq(reading.rows[1](600).title, "阅读页顶栏")

local popup_rows = Settings.popupRows(desktop)
Assert.len(popup_rows, 11)
Assert.eq(popup_rows[1](600).title, "选择")
Assert.eq(popup_rows[11](600).title, "搜索")

return true
