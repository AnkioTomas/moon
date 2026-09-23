--[[-- BookOrbit 快捷动作：只通过公开 ReaderUI 事件触发外部插件。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end

local events = {}
local plugin = { onBookOrbitSyncBook = function() end }
local ui = {
    bookorbit = plugin,
    handleEvent = function(_, event) events[#events + 1] = event end,
}

package.loaded["ui.panel.actions.reader.bookorbit"] = nil
local action = require("ui.panel.actions.reader.bookorbit")

Assert.eq(action.id, "bookorbit")
Assert.eq(action.title, "同步到 BookOrbit")
Assert.is_true(action.available({ ui = ui }))
Assert.is_false(action.available({ ui = {} }))
Assert.is_true(action.available({ ui = nil }))

action.run({ ui = ui })
Assert.eq(#events, 1)
Assert.eq(events[1].name, "BookOrbitSyncBook")

return true
