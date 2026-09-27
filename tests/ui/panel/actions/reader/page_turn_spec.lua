--[[-- 翻页动画快捷动作：阅读页只在动画开启时出现，点按打开风格选择。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end

local enabled = false
local picked = 0
package.preload["patch.page_turn_animation"] = function()
    return {
        isEnabled = function() return enabled end,
        pickStyle = function() picked = picked + 1 end,
    }
end

local action = require("ui.panel.actions.reader.page_turn")
Assert.eq(action.id, "page_turn")
Assert.eq(action.scope, "reader")
Assert.eq(action.title, "翻页动画")

local reader = { ui = {} }
Assert.is_false(action.available(reader), "动画关闭时阅读页不显示")
Assert.is_true(action.available({ ui = nil }), "设置页始终可配置")
Assert.is_true(action.available(nil))
enabled = true
Assert.is_true(action.available(reader))

action.run(reader)
Assert.eq(picked, 1)

return true
