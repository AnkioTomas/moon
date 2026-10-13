---@diagnostic disable: undefined-field, missing-fields, inject-field, assign-type-mismatch

--[[-- 设置「语言」行：一点即弹列表，只列插件有翻译的三种语言。 --]]

local Assert = require("support.assert")
local Themed = require("support.theme_stubs")
Themed.install()

package.preload["gettext"] = function() return function(text) return text end end
local changed
package.preload["ui/language"] = function()
    return {
        getLanguageName = function(_self, locale) return "name:" .. locale end,
        genLanguageSubItem = function(_self, locale)
            return {
                text = "name:" .. locale,
                checked_func = function() return locale == "zh_TW" end,
                callback = function() changed = locale end,
            }
        end,
    }
end
local row_opts
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) row_opts = opts return opts end }
end

local previous_settings = _G.G_reader_settings
_G.G_reader_settings = { readSetting = function(_self, key) return key == "language" and "zh_TW" or nil end }

local Language = require("desktop.pages.setting.language")
Language:row()(600)
Assert.eq(row_opts.title, "语言")
Assert.eq(row_opts.status, "name:zh_TW")

row_opts.callback()
local list = Themed.last("list")
Assert.len(list.items, 3)
Assert.eq(list.items[1].text, "name:zh_CN")
Assert.eq(list.items[2].text, "name:zh_TW")
Assert.eq(list.items[3].text, "name:C")
Assert.is_true(list.items[2].checked)
Assert.is_true(not list.items[1].checked)

Themed.choose(list, 3)
Assert.eq(changed, "C")

_G.G_reader_settings = previous_settings

return true
