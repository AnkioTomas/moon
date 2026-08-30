--[[-- Job 在无法 fork 时仍应给主线程一致的失败状态。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function() return false, "fork failed" end,
        isSubProcessDone = function() return true end,
    }
end
package.preload["ffi/posix"] = function()
    return {}
end
package.preload["workers.protocol"] = function()
    return { newDecoder = function() return {} end }
end
package.preload["workers.context"] = function()
    return {}
end

local Job = require("workers.job")
local states, failed = {}, nil
local job = Job.run(function() end, {
    on_state = function(state) states[#states + 1] = state end,
    on_failed = function(err) failed = err end,
})

Assert.eq(job.state, "failed")
Assert.eq(job.error, "fork failed")
Assert.eq(failed, "fork failed")
Assert.eq(states[1], "queued")
Assert.eq(states[2], "failed")
Assert.eq(job:status().state, "failed")
