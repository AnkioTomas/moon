--[[--
用法统计：按电量百分比随时间的变化估每小时耗电与剩余可用。

算法同 KOReader batterystat：累计唤醒 / 休眠 / 充电 / 放电四桶的 Δ% 与时长，
剩余可用 = 当前% / (Δ% / Δt)。不碰 mAh / 健康度——那些仍走 probe。

可注入 `_now` / `_capacity` / `_charging` 做离线测试。时长存秒。

@module koplugin.book.features.battery.stats
--]]

require("l10n").apply()
local _ = require("gettext")

local Stats = {}

--- 至少掉过这么多百分点、累计这么久，才报耗电率 / 预估；否则「样本不足」。
local MIN_PERCENT = 1
local MIN_SECONDS = 60

---@class BookBatteryUsage
---@field percentage number 累计绝对值变化
---@field time number 累计秒

---@class BookBatteryState
---@field percentage number
---@field timestamp number

---@type boolean
local ready = false
---@type boolean
local was_suspending = false
---@type boolean
local was_charging = false
---@type BookBatteryUsage
local awake
---@type BookBatteryUsage
local sleeping
---@type BookBatteryUsage
local charging
---@type BookBatteryUsage
local discharging
---@type BookBatteryState
local awake_state
---@type BookBatteryState
local charging_state

---@return number
local function now()
    if Stats._now then return Stats._now end
    return require("ui/time").to_s(require("ui/time").boottime_or_realtime_coarse())
end

---@return number
local function capacity()
    if Stats._capacity then return Stats._capacity end
    return require("device"):getPowerDevice():getCapacity() or 0
end

---@return boolean
local function isCharging()
    if Stats._charging ~= nil then return Stats._charging end
    return require("device"):getPowerDevice():isCharging() == true
end

---@return BookBatteryState
local function snapshot()
    return { percentage = capacity(), timestamp = now() }
end

---@param raw table|nil
---@return BookBatteryUsage
local function usage(raw)
    return {
        percentage = tonumber(raw and raw.percentage) or 0,
        time = tonumber(raw and raw.time) or 0,
    }
end

---@param bucket BookBatteryUsage
---@param state BookBatteryState
local function append(bucket, state)
    local curr = snapshot()
    local dt = curr.timestamp - state.timestamp
    if dt < 0 then dt = 0 end
    bucket.percentage = bucket.percentage + math.abs(state.percentage - curr.percentage)
    bucket.time = bucket.time + dt
end

local function settings()
    return require("utils.settings").get("features.battery")
end

local function persist()
    local data = settings()
    data.awake = { percentage = awake.percentage, time = awake.time }
    data.sleeping = { percentage = sleeping.percentage, time = sleeping.time }
    data.charging = { percentage = charging.percentage, time = charging.time }
    data.discharging = { percentage = discharging.percentage, time = discharging.time }
    data.awake_state = { percentage = awake_state.percentage, timestamp = awake_state.timestamp }
    data.charging_state = { percentage = charging_state.percentage, timestamp = charging_state.timestamp }
    data.was_charging = was_charging
    require("utils.settings").save("features.battery")
end

--- 把当前段并进对应桶，再打新快照。
local function accumulate()
    if was_suspending and not was_charging then
        append(sleeping, awake_state)
    elseif not was_suspending and not was_charging then
        append(awake, awake_state)
    end
    if was_charging then
        append(charging, charging_state)
    else
        append(discharging, charging_state)
    end
    awake_state = snapshot()
    charging_state = snapshot()
end

---@param with_charging boolean
---@param with_discharging boolean
local function resetBuckets(with_charging, with_discharging)
    awake = usage()
    sleeping = usage()
    if with_charging then charging = usage() end
    if with_discharging then discharging = usage() end
    awake_state = snapshot()
end

--- 首次调用装载落盘数据；充电中启动清空充放电累计，跨进程若电量上涨当充过电。
function Stats.ensure()
    if ready then return end
    local data = settings()
    awake = usage(data.awake)
    sleeping = usage(data.sleeping)
    charging = usage(data.charging)
    discharging = usage(data.discharging)
    awake_state = snapshot()
    charging_state = snapshot()
    was_suspending = false
    was_charging = isCharging()
    if was_charging then
        resetBuckets(true, false)
    end
    local before = data.awake_state
    if before and tonumber(before.percentage)
        and awake_state.percentage > tonumber(before.percentage) then
        resetBuckets(false, true)
    end
    ready = true
end

function Stats.onSuspend()
    Stats.ensure()
    if not was_suspending then accumulate() end
    was_suspending = true
    persist()
end

function Stats.onResume()
    Stats.ensure()
    if was_suspending then accumulate() end
    was_suspending = false
    persist()
end

function Stats.onCharging()
    Stats.ensure()
    if not was_charging then
        resetBuckets(true, true)
        accumulate()
    end
    was_charging = true
    persist()
end

function Stats.onNotCharging()
    Stats.ensure()
    if was_charging then
        resetBuckets(false, true)
        accumulate()
    end
    was_charging = false
    persist()
end

function Stats.save()
    if not ready then return end
    accumulate()
    persist()
end

function Stats.reset()
    Stats.ensure()
    resetBuckets(true, true)
    charging_state = snapshot()
    was_suspending = false
    was_charging = isCharging()
    persist()
end

---@param bucket BookBatteryUsage
---@return number|nil 每小时百分点；样本不足返回 nil
local function ratePerHour(bucket)
    if bucket.percentage < MIN_PERCENT or bucket.time < MIN_SECONDS then return nil end
    return bucket.percentage / bucket.time * 3600
end

---@param bucket BookBatteryUsage
---@param remaining boolean true=剩余可用，false=充满还需
---@return number|nil 秒
local function estimateSeconds(bucket, remaining)
    local rate = ratePerHour(bucket)
    if not rate or rate <= 0 then return nil end
    local pct = capacity()
    local need = remaining and pct or math.abs(pct - 100)
    return need / rate * 3600
end

---@param seconds number|nil
---@return string
function Stats.formatDuration(seconds)
    if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
        return _("样本不足")
    end
    local sec = math.floor(seconds)
    local days = math.floor(sec / 86400)
    local hours = math.floor((sec % 86400) / 3600)
    local mins = math.floor((sec % 3600) / 60)
    if days > 0 then
        return require("ffi/util").template(_("%1天%2:%3"), days,
            string.format("%02d", hours), string.format("%02d", mins))
    end
    return string.format("%02d:%02d", hours, mins)
end

---@param bucket BookBatteryUsage
---@return string
local function formatRate(bucket)
    local rate = ratePerHour(bucket)
    if not rate then return _("样本不足") end
    return string.format("%.2f%%", rate)
end

---@param bucket BookBatteryUsage
---@return string
local function formatConsumed(bucket)
    return string.format("%.2f%%", bucket.percentage)
end

--- 并入当前段后给出展示用摘要（不落盘；页面每 15 秒重算）。
---@return table
function Stats.summary()
    Stats.ensure()
    accumulate()
    return {
        capacity = capacity(),
        charging = was_charging,
        awake = {
            time = awake.time,
            consumed = formatConsumed(awake),
            rate = formatRate(awake),
            remaining = Stats.formatDuration(estimateSeconds(awake, true)),
        },
        sleeping = {
            time = sleeping.time,
            consumed = formatConsumed(sleeping),
            rate = formatRate(sleeping),
            remaining = Stats.formatDuration(estimateSeconds(sleeping, true)),
        },
        discharging = {
            time = discharging.time,
            consumed = formatConsumed(discharging),
            rate = formatRate(discharging),
            remaining = Stats.formatDuration(estimateSeconds(discharging, true)),
        },
        charging_usage = {
            time = charging.time,
            consumed = formatConsumed(charging),
            rate = formatRate(charging),
            remaining = Stats.formatDuration(estimateSeconds(charging, false)),
        },
    }
end

--- 测试用：清模块状态，下次 ensure 重装。
function Stats._resetForTest()
    ready = false
    Stats._now, Stats._capacity, Stats._charging = nil, nil, nil
end

return Stats
