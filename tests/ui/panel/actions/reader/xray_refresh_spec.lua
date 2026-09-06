--[[-- 刷新 X-Ray 快捷动作直接触发强制刷新入口。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end

local settings = {}
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end

local refreshed_ui
package.preload["xray.ui"] = function()
    return {
        refresh = function(ui) refreshed_ui = ui end,
    }
end

local action = require("ui.panel.actions.reader.xray_refresh")
Assert.eq(action.id, "xray_refresh")
Assert.eq(action.title, "刷新 X-Ray")
Assert.eq(action.icon, "sync")

settings.book_xray_enabled = nil
Assert.is_true(action.available())
settings.book_xray_enabled = false
Assert.is_false(action.available())

local reader_ui = {}
action.run({ ui = reader_ui })
Assert.eq(refreshed_ui, reader_ui)

return true
