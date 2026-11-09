--[[-- 刷新目录快捷动作：仅连续章节会话可用。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function()
    return function(value) return value end
end

local state = { chapter_mode = false, called = 0 }
package.preload["reader.session"] = function()
    return {
        isChapterMode = function() return state.chapter_mode end,
        refreshToc = function() state.called = state.called + 1 end,
    }
end

package.loaded["features.panel.actions.reader.refresh_toc"] = nil
local action = require("features.panel.actions.reader.refresh_toc")

Assert.eq(action.id, "refresh_toc")
Assert.eq(action.title, "刷新目录")
Assert.eq(action.scope, "reader")
Assert.is_true(action.available({}), "设置页无 ui 可勾选")
Assert.is_false(action.available({ ui = {} }), "整书不显示")
state.chapter_mode = true
Assert.is_true(action.available({ ui = {} }), "连续章节显示")

action.run()
Assert.eq(state.called, 1)
