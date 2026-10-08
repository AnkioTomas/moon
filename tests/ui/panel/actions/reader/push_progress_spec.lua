--[[-- Kavita：同步进度 快捷动作：仅 Kavita 可见，run 交给 book.progress.push。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(value) return value end end

local session
package.preload["ui.reader.session"] = function()
    return { current = function() return session end }
end

local pushed
package.preload["book.progress"] = function()
    return { push = function(s) pushed = s end }
end

local action = require("ui.panel.actions.reader.push_progress")
Assert.eq(action.id, "push_progress")
Assert.eq(action.title, "推送进度")
Assert.is_true(action.always_visible)

-- 设置页（无 ReaderUI）必须可用，否则勾选不上
Assert.is_true(action.available())
Assert.is_true(action.available({ ui = nil }))

-- 阅读页（有 ReaderUI）：仅 Kavita 显示
local reader_ctx = { ui = {} }
session = nil
Assert.is_false(action.available(reader_ctx))
session = { identity = { source_id = "wechat", stable_id = "b1" } }
Assert.is_false(action.available(reader_ctx))
session = { identity = { source_id = "kavita", stable_id = "42" } }
Assert.is_true(action.available(reader_ctx))

action.run({ ui = {} })
Assert.eq(pushed, session, "run 把当前会话交给 Progress.push")

return true
