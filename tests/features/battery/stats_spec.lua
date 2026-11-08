--[[-- 电池用法统计：唤醒 / 休眠累计、样本不足、充电重置。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ffi/util"] = function()
    return { template = function(text, a, b, c)
        return (text:gsub("%%1", tostring(a)):gsub("%%2", tostring(b)):gsub("%%3", tostring(c)))
    end }
end

local stored = {
    awake = { percentage = 0, time = 0 },
    sleeping = { percentage = 0, time = 0 },
    charging = { percentage = 0, time = 0 },
    discharging = { percentage = 0, time = 0 },
}
local saves = 0
package.preload["utils.settings"] = function()
    return {
        get = function(owner)
            Assert.eq(owner, "features.battery")
            return stored
        end,
        save = function(owner)
            Assert.eq(owner, "features.battery")
            saves = saves + 1
        end,
    }
end

package.loaded["features.battery.stats"] = nil
local Stats = require("features.battery.stats")
Stats._resetForTest()

Stats._now = 1000
Stats._capacity = 80
Stats._charging = false
Stats.ensure()

-- 唤醒 1 小时掉 2%：有耗电率与预估。
Stats._now = 1000 + 3600
Stats._capacity = 78
local sum = Stats.summary()
Assert.eq(sum.awake.consumed, "2.00%")
Assert.eq(sum.awake.rate, "2.00%")
Assert.eq(sum.awake.remaining, "1天15:00")
Assert.eq(sum.discharging.consumed, "2.00%")

-- 样本不足：休眠桶还没数据。
Assert.eq(sum.sleeping.rate, "样本不足")
Assert.eq(sum.sleeping.remaining, "样本不足")

-- 休眠段：suspend → 时间推进 → resume。
Stats._now = 1000 + 3600
Stats.onSuspend()
Stats._now = 1000 + 3600 + 7200
Stats._capacity = 77
Stats.onResume()
sum = Stats.summary()
Assert.eq(sum.sleeping.consumed, "1.00%")
Assert.eq(sum.sleeping.rate, "0.50%")

-- 充电切换清空放电累计。
Stats._capacity = 77
Stats.onCharging()
sum = Stats.summary()
Assert.eq(sum.discharging.consumed, "0.00%")
Assert.eq(sum.awake.consumed, "0.00%")

Stats._now = Stats._now + 1800
Stats._capacity = 86
Stats._charging = true
-- was_charging 已真，summary 把这段算进 charging。
sum = Stats.summary()
Assert.eq(sum.charging_usage.consumed, "9.00%")
Assert.eq(sum.charging_usage.rate, "18.00%")

-- 格式：超过一天。
Assert.eq(Stats.formatDuration(15 * 86400 + 4 * 3600 + 60), "15天04:01")
Assert.eq(Stats.formatDuration(3 * 3600 + 42 * 60), "03:42")
Assert.eq(Stats.formatDuration(nil), "样本不足")

-- 重置清空。
Stats.reset()
sum = Stats.summary()
Assert.eq(sum.awake.consumed, "0.00%")
Assert.eq(sum.charging_usage.consumed, "0.00%")
Assert.is_true(saves > 0)

return true
