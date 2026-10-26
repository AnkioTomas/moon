--[[-- 后台任务快捷动作：点开任务列表；有未结束任务时高亮。 --]]
---@diagnostic disable: undefined-field, missing-fields

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end

local pending = {}
package.preload["workers.tasks"] = function()
    return { tasks = function() return pending end }
end

local shown = 0
package.preload["workers.ui.task_dialog"] = function()
    return {
        new = function(self)
            Assert.is_nil(self.title, "列表弹窗不带参数")
            return { show = function() shown = shown + 1 end }
        end,
    }
end

local Action = require("features.panel.actions.desktop.tasks")
Assert.eq(Action.id, "tasks")
Assert.eq(Action.title, "后台任务")
Assert.eq(Action.icon, "download")
Assert.eq(Action.scope, "desktop")

Assert.is_false(Action.active())
pending = { { state = "queued" } }
Assert.is_true(Action.active(), "排队中也算未结束")

Action.run({})
Assert.eq(shown, 1)
Action.run({})
Assert.eq(shown, 2, "每次点按都新开一个列表")

return true
