--[[-- ui.panel.actions.layout 离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local opened
local Action = require("ui.panel.actions.layout")
Assert.eq(Action.id, "layout")
Assert.eq(Action.title, "布局")
Assert.eq(Action.scope, "reader")
Assert.is_nil(Action.keep_open)

local ui = {
    config = {
        onShowConfigMenu = function()
            opened = true
        end,
    },
}
Assert.is_true(Action.available({ ui = ui }))
Assert.is_true(Action.available({}))
Assert.is_false(Action.available({ ui = {} }))
Assert.is_false(Action.available({ ui = { config = {} } }))

Action.run({ ui = ui })
Assert.is_true(opened)
