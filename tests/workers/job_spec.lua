--[[--
Job：fork 失败语义，以及 scheduleIn 收 IPC（不挂 ZMQ）。
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local ffi = require("ffi")
pcall(function()
    ffi.cdef("int close(int);")
end)

Stubs.install()

package.preload["utils.log"] = function()
    return { dbg = function() end, warn = function() end }
end
package.loaded["utils.log"] = nil

local function jsonEncode(value)
    local t = type(value)
    if value == nil then return "null" end
    if t == "boolean" then return value and "true" or "false" end
    if t == "number" then return tostring(value) end
    if t == "string" then
        return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    end
    if t ~= "table" then error("json.encode: " .. t) end
    local n = #value
    if n > 0 then
        local parts = {}
        for i = 1, n do parts[i] = jsonEncode(value[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, v in pairs(value) do
        parts[#parts + 1] = jsonEncode(tostring(k)) .. ":" .. jsonEncode(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function jsonDecode(input)
    local i = 1
    local parse_value
    local function peek() return input:sub(i, i) end
    local function skip()
        while input:sub(i, i):match("%s") do i = i + 1 end
    end
    local function parse_string()
        i = i + 1
        local out = {}
        while true do
            local c = input:sub(i, i)
            if c == "" then error("bad string") end
            if c == '"' then
                i = i + 1
                return table.concat(out)
            end
            if c == "\\" then
                out[#out + 1] = input:sub(i + 1, i + 1)
                i = i + 2
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
    end
    local function parse_object()
        i = i + 1
        local obj = {}
        skip()
        if peek() == "}" then
            i = i + 1
            return obj
        end
        while true do
            skip()
            local key = parse_string()
            skip()
            assert(peek() == ":")
            i = i + 1
            obj[key] = parse_value()
            skip()
            local c = peek()
            if c == "}" then
                i = i + 1
                return obj
            end
            assert(c == ",")
            i = i + 1
        end
    end
    local function parse_array()
        i = i + 1
        local arr = {}
        skip()
        if peek() == "]" then
            i = i + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parse_value()
            skip()
            local c = peek()
            if c == "]" then
                i = i + 1
                return arr
            end
            assert(c == ",")
            i = i + 1
        end
    end
    parse_value = function()
        skip()
        local c = peek()
        if c == '"' then return parse_string() end
        if c == "{" then return parse_object() end
        if c == "[" then return parse_array() end
        if input:sub(i, i + 3) == "true" then
            i = i + 4
            return true
        end
        if input:sub(i, i + 4) == "false" then
            i = i + 5
            return false
        end
        if input:sub(i, i + 3) == "null" then
            i = i + 4
            return nil
        end
        local s, e = input:find("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        local n = tonumber(input:sub(s, e))
        i = e + 1
        return n
    end
    return parse_value()
end

package.preload["json"] = function()
    return { encode = jsonEncode, decode = jsonDecode }
end
package.loaded["json"] = nil

local util = {
    pending = "",
    alive = false,
    run = function()
        return false, "fork failed"
    end,
}
package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function(...)
            return util.run(...)
        end,
        isSubProcessDone = function()
            return not util.alive
        end,
        getNonBlockingReadSize = function()
            return #util.pending
        end,
        terminateSubProcess = function()
            util.alive = false
        end,
    }
end
package.loaded["ffi/util"] = nil

package.preload["ffi/posix"] = function()
    return {
        read = function(_, buffer, size)
            local n = math.min(#util.pending, size)
            if n > 0 then
                ffi.copy(buffer, util.pending:sub(1, n))
                util.pending = util.pending:sub(n + 1)
            end
            return n
        end,
    }
end
package.loaded["ffi/posix"] = nil

local zmq_inserts = 0
local UIManager = require("ui/uimanager")
local insertZMQ = UIManager.insertZMQ
function UIManager:insertZMQ(...)
    zmq_inserts = zmq_inserts + 1
    return insertZMQ(self, ...)
end

local Job = require("workers.job")
local Protocol = require("workers.protocol")
Assert.is_false(Job.inSubProcess())

Assert.errors(function()
    Job.run(function() end, { name = "test.kind" })
end, "kind must be")

local failed
local job = Job.run(function() end, {
    name = "test.fork",
    kind = "light",
    on_failed = function(err) failed = err end,
})
Assert.eq(job.state, "failed")
Assert.eq(job.error, "fork failed")
Assert.eq(failed, "fork failed")
Assert.eq(zmq_inserts, 0)

util.alive = false
util.pending = Protocol.encode({ type = "done", result = { files = 10 } })
util.run = function()
    return 42, 4095
end

local result
local done_job = Job.run(function() end, {
    name = "test.poll",
    kind = "light",
    on_done = function(value) result = value end,
})
Assert.eq(zmq_inserts, 0)
Assert.eq(done_job.state, "running")
Assert.eq(done_job.pid, 42)
Stubs.flush()
Assert.eq(zmq_inserts, 0)
Assert.eq(done_job.state, "done")
Assert.eq(result.files, 10)
Assert.is_nil(done_job.poll_fn)

-- 子进程 progress 帧按序转给 on_progress，之后 done 照常收尾。
util.alive = false
util.pending = Protocol.encode({ type = "progress", value = 3 })
    .. Protocol.encode({ type = "progress", value = 7 })
    .. Protocol.encode({ type = "done", result = { files = 1 } })
local seen_progress = {}
local progress_job = Job.run(function() end, {
    name = "test.progress",
    kind = "light",
    on_progress = function(value) seen_progress[#seen_progress + 1] = value end,
})
Stubs.flush()
Assert.eq(progress_job.state, "done")
Assert.eq(seen_progress[1], 3)
Assert.eq(seen_progress[2], 7)
Assert.len(seen_progress, 2)

util.alive = true
util.pending = Protocol.encode({ type = "done", result = { files = 9 } })
local cancelled_seen
local live = Job.run(function() end, {
    name = "test.cancel",
    kind = "heavy",
    on_cancelled = function() cancelled_seen = true end,
    on_done = function() error("cancel should not complete") end,
})
Assert.eq(zmq_inserts, 0)
live:cancel()
Assert.eq(live.state, "cancelled")
Assert.is_true(cancelled_seen)
Assert.is_nil(live.poll_fn)
Stubs.flush()
Assert.eq(live.state, "cancelled")

local instant_value
local instant_progress
local instant = Job.run(function(progress)
    progress(5)
    return 42
end, {
    name = "test.instant",
    kind = "instant",
    on_done = function(value) instant_value = value end,
    on_progress = function(value) instant_progress = value end,
})
Assert.eq(instant.state, "queued")
Assert.is_nil(instant.pid)
Stubs.flush()
Assert.eq(instant_value, 42)
Assert.eq(instant_progress, 5)
Assert.eq(instant.state, "done")

local called = false
local instant_cancelled
local cancelled = Job.run(function() called = true end, {
    name = "test.instant.cancel",
    kind = "instant",
    on_cancelled = function() instant_cancelled = true end,
    on_done = function() error("instant cancel should not complete") end,
})
cancelled:cancel()
Assert.is_true(cancelled.settled)
Assert.eq(cancelled.state, "cancelled")
Assert.is_true(instant_cancelled)
Assert.is_nil(cancelled.poll_fn)
Stubs.flush()
Assert.is_false(called)
Assert.eq(cancelled.state, "cancelled")

local instant_failed = Job.run(function() error("boom") end, {
    name = "test.instant.fail",
    kind = "instant",
})
Stubs.flush()
Assert.eq(instant_failed.state, "failed")
Assert.matches(instant_failed.error, "boom")

local System = require("workers.system")
local slots = System:concurrency()
Assert.is_true(slots >= 1)
Assert.is_true(slots <= 20)

function System:concurrency() return 1 end
util.alive = false
util.pending = Protocol.encode({ type = "done", result = { n = 1 } })
local first = Job.run(function() end, {
    name = "test.slot.a",
    kind = "light",
})
local second = Job.run(function() end, {
    name = "test.slot.b",
    kind = "light",
})
Assert.eq(first.state, "running")
Assert.eq(second.state, "queued")
second:cancel()
Assert.eq(second.state, "cancelled")
Stubs.flush()
Assert.eq(first.state, "done")
Assert.eq(second.state, "cancelled")
