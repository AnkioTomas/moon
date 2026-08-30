local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
local SimpleJob = require("workers/simple_job")

local states = {}
local value
local job = SimpleJob.run(function() return 42 end, {
    on_state = function(state) states[#states + 1] = state end,
    on_done = function(result) value = result end,
})

Assert.eq(job.state, "queued")
Stubs.flush()
Assert.eq(value, 42)
Assert.eq(job.state, "done")
Assert.eq(states[1], "queued")
Assert.eq(states[2], "running")
Assert.eq(states[3], "done")

local called = false
local cancelled = SimpleJob.nextTick(function() called = true end)
Assert.is_true(cancelled:cancel())
Assert.is_false(cancelled:cancel())
Stubs.flush()
Assert.is_false(called)
Assert.eq(cancelled.state, "cancelled")

local failed = SimpleJob.run(function() error("boom") end)
Stubs.flush()
Assert.eq(failed.state, "failed")
Assert.matches(failed.error, "boom")
