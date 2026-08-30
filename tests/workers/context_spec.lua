--[[-- Job 子进程上下文只在 enter/leave 区间可发送进度。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
local Context = require("workers.context")
local seen

Assert.is_false(Context.inSubProcess())
Context.enter(function(message)
    seen = message
    return true
end)
Assert.is_true(Context.inSubProcess())
Context.post({ current = 3 })
Assert.eq(seen.type, "progress")
Assert.eq(seen.value.current, 3)
Context.leave()
Assert.is_false(Context.inSubProcess())
Assert.errors(function() Context.post({}) end, "only available")
