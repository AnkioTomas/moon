--[[--
clock：时区经 TZ 在进程内生效；校时只在偏差超限时改系统时间；进入桌面没联网等联网补一次。
@module tests.features.clock.init_spec
--]]
---@diagnostic disable: missing-fields

local Assert = require("support.assert")
local Stubs = require("support.stubs")

Stubs.install()
local broadcasts = {}
require("ui/uimanager").broadcastEvent = function(_, ev) broadcasts[#broadcasts + 1] = ev.handler end

local conf = { timezone = "", ntp_auto = false, ntp_server = "ntp.example", ntp_last = 0 }
local saved = 0
package.loaded["utils.settings"] = {
    get = function(owner) assert(owner == "features.clock"); return conf end,
    save = function(owner) assert(owner == "features.clock"); saved = saved + 1 end,
}

local set_calls, set_ok, can_set = {}, true, true
package.loaded["device"] = {
    setDateTime = function(_, year, month, day, hour, min, sec)
        if not hour then return can_set or nil end
        set_calls[#set_calls + 1] = { year = year, month = month, day = day, hour = hour, min = min, sec = sec }
        return set_ok
    end,
    isEmulator = function() return false end,
}

local connected = true
package.loaded["ui/network/manager"] = { isConnected = function() return connected end }

local jobs, cancelled = {}, 0
package.loaded["workers.job"] = {
    run = function(worker, opts)
        local job = { worker = worker, opts = opts }
        function job.cancel() cancelled = cancelled + 1 end
        jobs[#jobs + 1] = job
        return job
    end,
}
local now = 1700000000
package.loaded["socket"] = { gettime = function() return now end }

local Clock = require("features.clock")

-- 时区：TZ 生效后 os.date 立即按新时区换算；跟随系统还原启动时的 TZ
do
    local before = os.date("%H:%M", 0)
    Clock.setTimezone("CST-8")
    Assert.eq(os.date("%H:%M", 0), "08:00")
    Assert.eq(Clock.timezoneLabel(), "UTC+8 北京、香港、台北、新加坡")
    Clock.setTimezone("IST-5:30")
    Assert.eq(os.date("%H:%M", 0), "05:30")
    Clock.setTimezone("EST5EDT,M3.2.0,M11.1.0")
    Assert.eq(os.date("%H", 1720000000), "05", "7 月走夏令时 UTC−4")
    Assert.eq(os.date("%H", 1700000000), "17", "11 月中旬是 UTC−5")
    Clock.setTimezone("")
    Assert.eq(os.date("%H:%M", 0), before)
    Assert.matches(Clock.timezoneLabel(), "^跟随系统（UTC")
    Assert.eq(saved, 4)
    Assert.eq(broadcasts[1], "onTimeFormatChanged", "通知页脚等时钟重画")
end

-- 校时：偏差超过 1 秒按本地时间设系统时间，记下校时时间
Clock.setTimezone("UTC0")
do
    local results = {}
    Assert.is_true(Clock.sync(function(ok, offset) results[#results + 1] = { ok, offset } end))
    Assert.is_false(Clock.sync(), "已有在飞的不重复发")
    Assert.len(jobs, 1)
    jobs[1].opts.on_done({ offset = 3600 })
    Assert.len(set_calls, 1)
    local t = set_calls[1]
    Assert.eq(string.format("%d-%02d-%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec),
        os.date("!%Y-%m-%d %H:%M:%S", now + 3600))
    Assert.eq(conf.ntp_last, os.time())
    Assert.is_true(results[1][1])
    Assert.eq(results[1][2], 3600)
end

-- 偏差小于 1 秒不动系统时间；子进程失败 / 设时间失败都回报失败、不记校时时间
do
    conf.ntp_last = 0
    local last
    Clock.sync(function(ok, offset, err) last = { ok, offset, err } end)
    jobs[#jobs].opts.on_done({ offset = 0.4 })
    Assert.len(set_calls, 1)
    Assert.is_true(last[1])

    conf.ntp_last = 0
    Clock.sync(function(ok, offset, err) last = { ok, offset, err } end)
    jobs[#jobs].opts.on_done({ err = "receive: timeout" })
    Assert.is_false(last[1])
    Assert.eq(last[3], "receive: timeout")

    Clock.sync(function(ok, offset, err) last = { ok, offset, err } end)
    jobs[#jobs].opts.on_failed("timeout")
    Assert.is_false(last[1])

    set_ok = false
    Clock.sync(function(ok, offset, err) last = { ok, offset, err } end)
    jobs[#jobs].opts.on_done({ offset = -120 })
    Assert.is_false(last[1])
    Assert.eq(last[2], -120)
    Assert.eq(conf.ntp_last, 0)
    set_ok = true
end

-- 子进程真的查询配置里的服务器
do
    local asked
    package.loaded["features.clock.ntp"] = { query = function(server) asked = server; return { offset = 0 } end }
    Clock.sync()
    Assert.eq(jobs[#jobs].worker().offset, 0)
    Assert.eq(asked, "ntp.example")
    jobs[#jobs].opts.on_done({ offset = 0 })
end

-- 进入桌面：关着不校时；没联网等联网补一次；联网了直接校时
do
    local count = #jobs
    conf.ntp_last = 0
    Clock.autoSync()
    Assert.len(jobs, count, "默认关闭")

    conf.ntp_auto = true
    connected = false
    Clock.autoSync()
    Assert.len(jobs, count, "没联网不发")
    connected = true
    Clock.onNetworkConnected({})
    Assert.len(jobs, count + 1, "联网后补一次")
    jobs[#jobs].opts.on_done({ offset = 0 })
    Clock.onNetworkConnected({})
    Assert.len(jobs, count + 1, "补过了不再重复")

    Clock.autoSync()
    Assert.len(jobs, count + 1, "6 小时内校过：进桌面不再起子进程")
    conf.ntp_last = os.time() - 7 * 3600
    Clock.autoSync()
    Assert.len(jobs, count + 2)
    Clock.onExit({})
    Assert.eq(cancelled, 1, "退出取消在飞的校时")
    Assert.is_true(Clock.sync(), "取消后可以重新发")
    Clock.onExit({})

    can_set = false
    Clock.autoSync()
    Assert.len(jobs, count + 3, "设备不能改时间就不校时")
end

Clock.setTimezone("")
