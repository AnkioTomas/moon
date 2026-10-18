--[[--
source.wechat.app 离线用例：签名对照官方 App 抓包，小时分桶。

@module tests.wechat.app_spec
--]]
---@diagnostic disable: undefined-field

local Assert = require("support.assert")
local App = require("source.wechat.app")

-- HAR 里官方 App 的一条 /book/read：同样的输入必须得到同样的 signature。
local payload = table.concat({
    "393727764", "35645832171399234841676621530100678335", "35645832171399234841676621530100678335",
    "CB_00K1XI1aSDlZ76f75hG9n7JG", "0", "+08:00", "81", "0",
}, "_") .. "_1792317600_+08:00_81_0"
Assert.eq(
    App.sign({ "5ecdcfd7f", "821", "1792318161", payload }),
    "dfd6f2ceb1e4a5d1152c6d19fd9c9f84115cad69989ee799faec377d05d8a833"
)

-- 跨整点的区间拆进两个小时桶，按整点升序。
local hours = App.hours({
    { start_time = 7300, duration = 10 },
    { start_time = 3590, duration = 20 },
}, "+08:00")
Assert.len(hours, 3)
Assert.eq(hours[1].startOfHour, 0)
Assert.eq(hours[1].readingTime, 10)
Assert.eq(hours[2].startOfHour, 3600)
Assert.eq(hours[2].readingTime, 10)
Assert.eq(hours[3].startOfHour, 7200)
Assert.eq(hours[3].readingTime, 10)
