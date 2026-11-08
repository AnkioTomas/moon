--[[-- 阅读设置快捷动作：打开设置「阅读」分组。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

local opened_plugin
package.preload["desktop.pages.setting"] = function()
    return {
        openReader = function(plugin)
            opened_plugin = plugin
            return true
        end,
    }
end

package.loaded["features.panel.actions.reader.settings"] = nil
local action = require("features.panel.actions.reader.settings")

Assert.eq(action.id, "settings")
Assert.eq(action.scope, "reader")
Assert.eq(action.title, "阅读设置")
Assert.is_true(action.available(nil))
Assert.is_true(action.available({}))
Assert.is_true(action.available({ ui = { document = {} } }))
Assert.is_false(action.available({ ui = {} }))

local plugin = { name = "book" }
action.run({ ui = { book = plugin, document = {} } })
Assert.eq(opened_plugin, plugin)
