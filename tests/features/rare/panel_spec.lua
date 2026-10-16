--[[-- features.rare.panel：阅读快捷面板「生僻字注音」开关；没词库时提示不打开。 --]]
local Assert = require("support.assert")
local settings = { rare_enabled = false }
local saved, invalidated, toasts, active = 0, 0, {}, {}
package.loaded["utils.settings"] = { get = function() return settings end, save = function() saved = saved + 1 end }
package.loaded["features.rare.overlay"] = { invalidate = function() invalidated = invalidated + 1 end }
package.loaded["features.rare.catalog"] = { active = function() return active end }
package.loaded["ui.themes.widgets.toast"] = { new = function(_self, o) toasts[#toasts + 1] = o.text return { show = function() end } end }

local action = require("features.rare.panel").actions()[1]
Assert.eq(action.id, "rare_ruby")
Assert.eq(action.scope, "reader")
Assert.is_false(action.active())
action.run()
Assert.is_false(settings.rare_enabled, "没词库不打开")
Assert.len(toasts, 1)
active = { {} }
action.run()
Assert.is_true(settings.rare_enabled)
Assert.is_true(action.active())
Assert.eq(saved, 1)
Assert.eq(invalidated, 1, "切换后重画")
action.run()
Assert.is_false(settings.rare_enabled)
