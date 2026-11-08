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

-- 离线批量的外层签名是 sha256(timestamp + token + random)，不是单本 guest 签名。
local sha256 = require("ffi/sha2").sha256
local batch = App.batchBody({ { bookId = "1" } }, "trouble")
Assert.eq(batch.books[1].bookId, "1")
Assert.eq(batch.recordCreateTimeZone, App.timeZone())
Assert.eq(batch.signature, sha256(tostring(batch.timestamp) .. "trouble" .. tostring(batch.random)))

-- 没有小时桶时 payload 以 _ 结尾，和 App generatePayLoad 一致。有小时桶时这个 _ 就是分隔符，不能再多一个。
local old_time, old_random = os.time, math.random
os.time = function() return 1700000000 end
math.random = function() return 7 end
local empty = App.readBody({
    vid = "1", device_id = "d", install_id = "i", guest_token = "gt",
    book_id = "b", chapter_uid = 1, chapter_idx = 1, chapter_offset = 0,
    chapter_progress = 0, current_progress = 0, progress = 0, hours = {},
})
local empty_payload = table.concat({ "1", "d", "d", "b", "0", App.timeZone(), "0", "0" }, "_") .. "_"
Assert.eq(empty.signature, App.sign({ "gt", "7", "1700000000", empty_payload }))
Assert.is_nil(empty.readUpdateTime)
Assert.is_nil(empty.isResendReadingInfo)
local spanned = App.readBody({
    vid = "1", device_id = "d", install_id = "i", guest_token = "gt",
    book_id = "b", chapter_uid = 1, chapter_idx = 1, chapter_offset = 0,
    chapter_progress = 0, current_progress = 40, progress = 99,
    hours = { { startOfHour = 3600, readingTime = 5, timeZone = "+08:00", ttsTime = 0 } },
    resend = 1, read_update = 1699990000,
})
local spanned_payload = table.concat({
    "1", "d", "d", "b", "0", App.timeZone(), "5", "0", "3600", "+08:00", "5", "0",
}, "_")
Assert.eq(spanned.signature, App.sign({ "gt", "7", "1700000000", spanned_payload }))
Assert.eq(spanned.progress, 99)
Assert.eq(spanned.currentProgress, 40)
Assert.eq(spanned.readUpdateTime, 1699990000)
Assert.eq(spanned.isResendReadingInfo, 1)
os.time, math.random = old_time, old_random
