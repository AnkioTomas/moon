--[[-- 自动补目录快捷动作：仅整书滚动文档可用，设置页可勾选。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

local state = { chapter_mode = false, called = 0 }
package.preload["reader.session"] = function()
    return {
        isChapterMode = function() return state.chapter_mode end,
        autoToc = function()
            state.called = state.called + 1
            return true
        end,
    }
end

package.loaded["features.panel.actions.reader.auto_toc"] = nil
local action = require("features.panel.actions.reader.auto_toc")

Assert.eq(action.id, "auto_toc")
Assert.eq(action.title, "自动补目录")
Assert.eq(action.icon, "list_alt_add")
Assert.eq(action.scope, "reader")
Assert.is_true(action.available({}), "设置页无 ui 可勾选")
Assert.is_false(action.available({ ui = {} }), "无 rolling/handmade 不显示")
Assert.is_true(action.available({ ui = { rolling = {}, handmade = {} } }), "整书滚动文档显示")

state.chapter_mode = true
Assert.is_false(action.available({ ui = { rolling = {}, handmade = {} } }), "连续章节不显示")
state.chapter_mode = false

action.run()
Assert.eq(state.called, 1)

local enabled = false
for _idx, id in ipairs(require("features.panel.setting").defaults.quick_panel_reader_actions) do
    if id == action.id then enabled = true end
end
Assert.is_true(enabled, "新安装默认启用自动补目录")
