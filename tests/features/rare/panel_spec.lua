--[[-- features.rare.panel：阅读快捷面板「生僻字注音」二级菜单（开关 + 三档范围）；没词库时提示不打开。 --]]
local Assert = require("support.assert")
local settings = { rare_enabled = false, rare_level = "rare" }
local saved, invalidated, toasts, active, lists = 0, 0, {}, {}, {}
package.loaded["utils.settings"] = { get = function() return settings end, save = function() saved = saved + 1 end }
package.loaded["features.rare.overlay"] = { invalidate = function() invalidated = invalidated + 1 end }
package.loaded["features.rare.catalog"] = { active = function() return active end }
package.loaded["ui.themes.widgets.toast"] = { new = function(_self, o) toasts[#toasts + 1] = o.text return { show = function() end } end }
package.loaded["ui.themes.widgets.list"] = { new = function(_self, o) lists[#lists + 1] = o return { show = function() end } end }
package.loaded["ui/uimanager"] = { setDirty = function() end }

local action = require("features.rare.panel").actions()[1]
Assert.eq(action.id, "rare_ruby")
Assert.eq(action.scope, "reader")
Assert.is_false(action.active())

action.run({})
local menu = lists[1]
Assert.len(menu.items, 4)
Assert.is_false(menu.items[1].checked)
Assert.is_true(menu.items[3].checked, "当前档位 rare")
menu.items[1].callback()
Assert.is_false(settings.rare_enabled, "没词库不打开")
Assert.len(toasts, 1)

active = { {} }
menu.items[1].callback()
Assert.is_true(settings.rare_enabled)
Assert.is_true(action.active())

menu.items[2].callback()
Assert.eq(settings.rare_level, "rarest")
menu.items[4].callback()
Assert.eq(settings.rare_level, "all")
Assert.is_true(settings.rare_enabled)

settings.rare_enabled = false
menu.items[3].callback()
Assert.eq(settings.rare_level, "rare")
Assert.is_true(settings.rare_enabled, "选范围顺带打开")
