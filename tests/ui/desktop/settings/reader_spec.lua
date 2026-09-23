--[[-- 阅读设置：行为一组，划词能力一组。 --]]

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
package.preload["patch.page_turn_animation"] = function()
    return { isEnabled = function() return false end }
end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/uimanager"] = function() return {} end

_G.G_reader_settings = {
    isTrue = function() return false end,
    saveSetting = function() end,
}

local Settings = require("ui.desktop.settings.reader")
local desktop = {}

local sections = Settings.new():sections(desktop)
Assert.eq(#sections, 1)
Assert.eq(sections[1].title, "行为")
Assert.eq(sections[1].rows[1](600).title, "脚注弹窗")
Assert.is_false(sections[1].rows[1](600).status_on)
Assert.eq(sections[1].rows[2](600).title, "翻页动画")
Assert.eq(sections[1].rows[3](600).title, "读到 99% 自动标记已读")

local lookup = Settings.new():lookupSections(desktop)
local titles = {}
for _, section in ipairs(lookup) do
    titles[#titles + 1] = section.title
end
Assert.eq(titles[1], "选区")
Assert.eq(titles[2], "词典")
Assert.eq(titles[3], "翻译")
Assert.eq(titles[4], "百科")
Assert.eq(titles[5], "X-Ray")
Assert.eq(lookup[1].rows[1](600).title, "划词手柄")
Assert.is_true(lookup[1].rows[1](600).status_on)

local popup_rows = Settings.new():popupRows(desktop)
Assert.len(popup_rows, 11)
Assert.eq(popup_rows[1](600).title, "选择")
Assert.eq(popup_rows[11](600).title, "搜索")

return true
