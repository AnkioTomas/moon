--[[--
lockscreen 阅读账单：所有统计查询绑定当前源。

@module tests.lockscreen.components.bill_spec
--]]

local Assert = require("support.assert")

local sources = {}
local function record(source_id)
    sources[#sources + 1] = source_id
end

package.preload["db.stats"] = function()
    return {
        periodDays = function(source_id)
            record(source_id)
            return {}
        end,
        periodHours = function(source_id)
            record(source_id)
            return {}
        end,
        periodSummary = function(source_id)
            record(source_id)
            return {}
        end,
        periodBooks = function(source_id)
            record(source_id)
            return {}
        end,
    }
end

package.preload["ui.components.chart"] = function()
    return { appendBars = function() end }
end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 255 }
end

package.preload["lockscreen.components.library"] = function()
    return { activeSourceId = function() return "moon" end }
end

package.preload["lockscreen.components.util"] = function()
    return {
        dayStart = function() return 100000 end,
        dayBuckets = function() return {} end,
        MUTED = 1,
        DIM = 2,
        RULE = 3,
    }
end

package.preload["utils.settings"] = function()
    return {
        get = function()
            return {
                active_source = "wrong-source",
                lock_screen_bill_period = "7d",
            }
        end,
    }
end

package.loaded["lockscreen.components.bill"] = nil
local Bill = require("lockscreen.components.bill")
Bill.data()

Assert.eq(#sources, 3)
for _, source_id in ipairs(sources) do
    Assert.eq(source_id, "moon")
end
