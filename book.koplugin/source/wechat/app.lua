--[[--
微信读书手机 App 协议（``POST /book/read``）：按小时分桶的阅读时长上报。

与 Web 的 ``/web/book/read``（每 30 秒心跳、rt）不同，App 把时长按 ``hours`` 分桶，
``timestamp`` 是发送时刻，历史时间只存在于 ``hours[].startOfHour``，所以离线攒下的
时长可以事后补报。签名来自 App 内 ``libencrypt.so`` 的 ``GenSignature``
（输入逐字节过替换表 → 加盐排序拼接 → 按异或值循环移位 → sha256，连做两轮），
用 HAR 抓包的真实请求核对过。

@module koplugin.book.source.wechat.app
--]]

local bit = require("bit")
local sha256 = require("ffi/sha2").sha256

local App = {}

local SALT = "5a6f1"

local REMAP = {
    52, 202, 85, 64, 29, 182, 147, 198, 49, 48, 41, 53, 50, 167, 184, 17,
    194, 181, 22, 250, 139, 177, 36, 164, 16, 144, 4, 233, 8, 248, 59, 138,
    156, 140, 68, 249, 188, 92, 105, 226, 161, 218, 210, 211, 117, 137, 247, 30,
    45, 80, 86, 215, 114, 83, 191, 34, 251, 32, 15, 1, 46, 69, 135, 110,
    102, 72, 242, 224, 205, 254, 103, 169, 67, 244, 148, 81, 206, 165, 74, 238,
    19, 38, 142, 204, 170, 51, 20, 93, 14, 57, 187, 207, 145, 43, 129, 77,
    234, 153, 236, 26, 44, 133, 197, 217, 54, 116, 75, 24, 225, 241, 61, 157,
    65, 159, 180, 23, 13, 214, 76, 190, 220, 175, 151, 40, 119, 240, 98, 255,
    113, 193, 200, 39, 143, 108, 104, 168, 155, 230, 89, 28, 27, 18, 9, 152,
    78, 63, 6, 55, 0, 186, 31, 10, 25, 47, 201, 213, 208, 87, 73, 111,
    253, 37, 228, 97, 12, 66, 203, 150, 100, 95, 219, 173, 96, 35, 141, 154,
    109, 195, 196, 94, 62, 185, 146, 106, 189, 91, 7, 127, 118, 149, 237, 79,
    171, 132, 122, 128, 231, 120, 199, 229, 235, 115, 131, 107, 252, 56, 70, 125,
    71, 101, 179, 82, 99, 58, 5, 209, 239, 163, 166, 222, 158, 60, 2, 174,
    178, 123, 160, 246, 243, 42, 192, 172, 134, 3, 90, 84, 11, 245, 130, 212,
    126, 227, 223, 176, 216, 221, 33, 232, 124, 136, 162, 121, 88, 112, 183, 21,
}

--- 逐字节比较，不走 strcoll：区域设置会改变高位字节的顺序。
---@param a string
---@param b string
---@return boolean
local function byteLess(a, b)
    local n = math.min(#a, #b)
    for i = 1, n do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then return x < y end
    end
    return #a < #b
end

--- 全部字节异或后取 mod 11 作偏移，整体循环移位。
---@param s string
---@return string
local function rotate(s)
    local x = 0
    for i = 1, #s do x = bit.bxor(x, s:byte(i)) end
    local k, n = x % 11, #s
    local out = {}
    for i = 0, n - 1 do out[(k + i) % n + 1] = s:sub(i + 1, i + 1) end
    return table.concat(out)
end

--- App 防重放签名。
---@param items string[] guest_token、random、timestamp、payload
---@return string
function App.sign(items)
    local list = {}
    for _idx, item in ipairs(items) do
        list[#list + 1] = (item:gsub(".", function(c) return string.char(REMAP[c:byte() + 1]) end))
    end
    list[#list + 1] = SALT
    table.sort(list, byteLess)
    local first = sha256(rotate(table.concat(list))) --[[@as string]]
    return sha256(rotate(first)) --[[@as string]]
end

--- 本机时区，形如 ``+08:00``。
---@return string
function App.timeZone()
    local z = os.date("%z") --[[@as string]]
    return z:sub(1, 3) .. ":" .. z:sub(4, 5)
end

---@class WechatAppHour
---@field startOfHour integer 整点 Unix 时间戳
---@field readingTime integer 秒
---@field timeZone string
---@field ttsTime integer

--- 把 [start, start+duration) 的阅读区间按整点切进小时桶（跨整点就拆开）。
---@param spans { start_time: integer, duration: integer }[]
---@param zone string
---@return WechatAppHour[] 按整点升序
function App.hours(spans, zone)
    local buckets = {}
    for _idx, span in ipairs(spans) do
        local at, left = span.start_time, span.duration
        while left > 0 do
            local hour = at - at % 3600
            local part = math.min(left, hour + 3600 - at)
            local bucket = buckets[hour]
            if not bucket then
                bucket = { startOfHour = hour, readingTime = 0, timeZone = zone, ttsTime = 0 }
                buckets[hour] = bucket
            end
            bucket.readingTime = bucket.readingTime + part
            at, left = at + part, left - part
        end
    end
    local out = {}
    for _hour, bucket in pairs(buckets) do out[#out + 1] = bucket end
    table.sort(out, function(a, b) return a.startOfHour < b.startOfHour end)
    return out
end

--- signature 的 payload：vid_deviceId_appId_bookId_risk_时区_readingTime_ttsTime_各小时桶。
---@param vid string
---@param body table
---@return string
local function signPayload(vid, body)
    local parts = {
        vid, body.deviceId, body.appId, body.bookId, tostring(body.risk),
        body.recordCreateTimeZone, tostring(body.readingTime), tostring(body.ttsTime),
    }
    for _idx, hour in ipairs(body.hours) do
        parts[#parts + 1] = hour.startOfHour .. "_" .. hour.timeZone .. "_" .. hour.readingTime .. "_" .. hour.ttsTime
    end
    return table.concat(parts, "_")
end

---@class WechatAppReadOpts
---@field vid string
---@field device_id string
---@field install_id string
---@field guest_token string
---@field book_id string
---@field chapter_uid integer
---@field chapter_idx integer
---@field chapter_offset integer 章内偏移（0..10000）
---@field chapter_progress integer 章内百分比 0..100
---@field hours WechatAppHour[]
---@field current_progress integer|nil 全书进度百分比 0..100（上报进度时带上）
---@field summary string|nil 当前位置摘要
---@field book_version integer|nil

--- 组装已签名的 ``/book/read`` 请求体。
---@param opts WechatAppReadOpts
---@return table
function App.readBody(opts)
    local total = 0
    for _idx, hour in ipairs(opts.hours) do total = total + hour.readingTime end
    local body = {
        appId = opts.device_id,
        autoTime = 0,
        bookId = opts.book_id,
        bookVersion = opts.book_version or 0,
        chapterIdx = opts.chapter_idx,
        chapterOffset = opts.chapter_offset,
        chapterProgress = opts.chapter_progress,
        chapterUid = opts.chapter_uid,
        currentProgress = opts.current_progress,
        deviceId = opts.device_id,
        hours = opts.hours,
        installId = opts.install_id,
        isLecture = 0,
        isStoryFeed = 0,
        lectureTextTime = 0,
        lectureTime = 0,
        novalTime = 0,
        random = math.random(0, 999),
        readingTime = total,
        recordCreateTimeZone = App.timeZone(),
        reviewId = "",
        risk = 0,
        sourceModule = "unknown",
        summary = opts.summary or "",
        timestamp = os.time(),
        ttsTime = 0,
        voiceType = -1,
        wordCount = 0,
    }
    body.signature = App.sign({
        opts.guest_token, tostring(body.random), tostring(body.timestamp), signPayload(opts.vid, body),
    })
    return body
end

return App
