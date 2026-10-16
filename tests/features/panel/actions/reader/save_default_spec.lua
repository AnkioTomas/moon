--[[-- 阅读页「保存为默认配置」快捷动作离线用例。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

local state = { saved = 0, toasts = {} }
package.preload["reader.prefs"] = function()
    return { saveDefaults = function(ui) state.saved = state.saved + 1; return ui.ok end }
end
package.preload["ui.themes.widgets.confirm"] = function()
    return { new = function(_self, o) return { show = function() state.confirm = o end } end }
end
package.preload["ui.themes.widgets.toast"] = function()
    return { new = function(_self, o) return { show = function() state.toasts[#state.toasts + 1] = o.text end } end }
end

package.loaded["features.panel.actions.reader.save_default"] = nil
local action = require("features.panel.actions.reader.save_default")

Assert.is_true(action.available(nil))
Assert.is_false(action.available({ ui = { document = {} } }))
Assert.is_true(action.available({ ui = { document = { configurable = {} } } }))

-- 先弹确认框，确认前不写默认值。
action.run({ ui = { ok = true } })
Assert.eq(state.saved, 0)
Assert.not_nil(state.confirm)
state.confirm.ok_callback()
Assert.eq(state.saved, 1)
Assert.eq(state.toasts[1], "已保存为默认配置")

action.run({ ui = { ok = false } })
state.confirm.ok_callback()
Assert.eq(state.toasts[2], "当前文档不支持保存默认配置")

return true
