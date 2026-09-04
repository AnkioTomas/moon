--[[-- 性能计时使用毫秒墙钟并输出非负耗时。 --]]

local Assert = require("support.assert")

local values = { 1, 1.0025 }
package.preload["socket"] = function()
    return {
        gettime = function() return table.remove(values, 1) end,
    }
end
package.loaded["socket"] = nil
package.loaded["utils.perf"] = nil

local Perf = require("utils.perf")
local started_at = Perf.now()
Assert.eq(Perf.elapsedMs(started_at), 3)
