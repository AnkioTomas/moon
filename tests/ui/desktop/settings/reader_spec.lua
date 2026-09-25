--[[-- 阅读设置：行为一组，划词能力一组。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ffi/util"] = function()
    return {
        template = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end,
    }
end
local reader_section = {}
local saved_section
package.preload["utils.settings"] = function()
    return {
        get = function() return reader_section end,
        saveSection = function(name, values) saved_section = { name = name, values = values } end,
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
local updates = 0
local desktop = { updateView = function() updates = updates + 1 end }

local sections = Settings:sections(desktop)
Assert.eq(#sections, 1)
Assert.eq(sections[1].title, "行为")
Assert.eq(sections[1].rows[1](600).title, "脚注弹窗")
Assert.is_false(sections[1].rows[1](600).status_on)
Assert.eq(sections[1].rows[2](600).title, "翻页动画")
local auto_mark = sections[1].rows[3](600)
Assert.eq(auto_mark.title, "读到 99% 自动标记已读")
Assert.eq(auto_mark.kind, "toggle")
Assert.eq(auto_mark.status, "关")
Assert.is_false(auto_mark.status_on)
auto_mark.callback()
Assert.is_true(reader_section.auto_mark_read_at_99)
Assert.eq(saved_section.name, "reader")
Assert.eq(updates, 1)
reader_section = {}

local lookup = Settings:lookupSections(desktop)
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
Assert.eq(lookup[5].rows[3](600).title, "X-Ray 下划线样式")
Assert.eq(lookup[5].rows[3](600).status, "虚线")

local popup_rows = Settings:popupRows(desktop)
Assert.len(popup_rows, 11)
Assert.eq(popup_rows[1](600).title, "选择")
Assert.eq(popup_rows[11](600).title, "搜索")

-- 旧配置缺键：设置页显示的位次必须和实际弹窗顺序（HighlightMenu.order）一致。
reader_section = { reader_popup_button_order = { "copy" } }
local order = require("ui.reader.highlight_menu").order()
local dictionary_pos
for i, key in ipairs(order) do
    if key == "dictionary" then dictionary_pos = i end
end
Assert.eq(popup_rows[6](600).title, "词典")
Assert.eq(popup_rows[6](600).status, "第 " .. dictionary_pos .. " 位")

return true
