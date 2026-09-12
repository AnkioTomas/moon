--[[-- workers.system：按自身 concurrency 限流，排队任务等槽位。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local ffi = require("ffi")
pcall(function()
    ffi.cdef("int close(int);")
end)

Stubs.install()

package.preload["utils.log"] = function()
    return { dbg = function() end }
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
    if #value > 0 then
        local parts = {}
        for i = 1, #value do parts[i] = jsonEncode(value[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, v in pairs(value) do
        parts[#parts + 1] = jsonEncode(tostring(k)) .. ":" .. jsonEncode(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

package.preload["json"] = function()
    return {
        encode = jsonEncode,
        decode = function(s)
            if type(s) == "string" and s:find('"type":"done"', 1, true) then
                return { type = "done", result = { ok = true } }
            end
            return {}
        end,
    }
end
package.loaded["json"] = nil

local util = {
    pending = "",
    alive = true,
    run = function()
        return 7, 3
    end,
}
package.preload["ffi/util"] = function()
    return {
        runInSubProcess = function()
            return util.run()
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

local Job = require("workers.job")
local System = require("workers.system")
local Protocol = require("workers.protocol")

function System:concurrency() return 1 end
util.alive = false
util.pending = Protocol.encode({ type = "done", result = { ok = true } })
local a = Job.run(function() end, { name = "sys.a", kind = "medium" })
local b = Job.run(function() end, { name = "sys.b", kind = "medium" })
Assert.eq(a.state, "running")
Assert.eq(b.state, "queued")
b:cancel()
Stubs.flush()
Assert.eq(a.state, "done")
Assert.eq(b.state, "cancelled")
