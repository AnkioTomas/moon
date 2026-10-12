--[[-- 推送 / 拉取进度快捷动作：属主源有对应接口才在阅读页出现，设置页总能勾选；点了交给阅读期进度。 --]]

local Assert = require("support.assert")

local current
package.preload["reader.session"] = function()
    return { current = function() return current end }
end
local calls = {}
package.preload["reader.session.progress"] = function()
    return {
        push = function(snapshot) calls[#calls + 1] = { "push", snapshot } end,
        pull = function(snapshot, opts) calls[#calls + 1] = { "pull", snapshot, opts } end,
    }
end

local push = require("features.panel.actions.reader.push_progress")
local pull = require("features.panel.actions.reader.pull_progress")
Assert.eq(push.id, "push_progress")
Assert.eq(pull.id, "pull_progress")
Assert.eq(push.scope, "reader")

local ctx = { ui = {} }
Assert.is_true(push.available({ ui = nil }), "设置页没有会话也能勾选")
Assert.is_false(push.available(ctx), "没在读")
current = { identity = { source = {} } }
Assert.is_false(push.available(ctx), "源不能上报进度")
Assert.is_false(pull.available(ctx))
current.identity.source = { putProgressAsync = function() end, getProgressAsync = function() end }
Assert.is_true(push.available(ctx))
Assert.is_true(pull.available(ctx))

push.run(ctx)
pull.run(ctx)
Assert.eq(calls[1][1], "push")
Assert.eq(calls[1][2], current)
Assert.eq(calls[2][1], "pull")
Assert.is_true(calls[2][3].manual)
