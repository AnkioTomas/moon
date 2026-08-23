--[[-- ui.panel.actions.layout 离线用例。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

local shown_ui
package.preload["ui.reader.layout"] = function()
    return {
        isReflowable = function(ui)
            return ui ~= nil and ui.rolling ~= nil
        end,
        matchId = function(ui)
            return ui and ui.layout_id or "off"
        end,
        showMenu = function(ui)
            shown_ui = ui
        end,
    }
end

local Action = require("ui.panel.actions.layout")
Assert.eq(Action.id, "layout")
Assert.eq(Action.scope, "reader")

local reflowable = { rolling = {}, layout_id = "book" }
Assert.is_true(Action.available({ ui = reflowable }))
Assert.is_true(Action.active({ ui = reflowable }))
Assert.is_false(Action.available({ ui = {} }))
Assert.is_false(Action.active({ ui = { rolling = {}, layout_id = "off" } }))

Action.run({ ui = reflowable })
Assert.eq(shown_ui, reflowable)
