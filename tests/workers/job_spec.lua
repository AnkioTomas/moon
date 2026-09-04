--[[-- Job 在无法 fork 时仍应给主线程一致的失败状态。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
local logs = {}
package.preload["utils.log"] = function()
    return {
        dbg = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
            logs[#logs + 1] = table.concat(parts, " ")
        end,
    }
end
package.loaded["utils.log"] = nil
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
    name = "test.fork",
    on_state = function(state) states[#states + 1] = state end,
    on_failed = function(err) failed = err end,
})

Assert.eq(job.state, "failed")
Assert.eq(job.name, "test.fork")
Assert.eq(job.error, "fork failed")
Assert.eq(failed, "fork failed")
Assert.eq(states[1], "queued")
Assert.eq(states[2], "failed")
Assert.eq(job:status().state, "failed")
Assert.eq(job:status().name, "test.fork")
Assert.not_nil(table.concat(logs, "\n"):find("book.worker queued test.fork #1", 1, true))
