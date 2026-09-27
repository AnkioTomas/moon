--[[--
微信读书阅读统计：累计总量、账户日桶与单书明细 wire → reading_stats 领域行。

账户级日桶 ``__wr:day:<ts>``；权威累计时长 ``__wr:total``，不参与日历分桶求和。
单书（stable_id 即 bookId）：``book_total`` 为书架 ``readingTime`` 快照（start_time=拉取时间），
``book_day`` 为 readinfo 按日明细（start_time=当天零点）。云端按日求和本就不等于累计，两者不互推。
日桶 / book_day 的 last_time 记拉取时间：展示时补上拉取之后本地新读的时长。
入库前按各合成前缀的时间窗口、按书精确替换旧记录，避免重复累计。

@module koplugin.book.source.wechat.stats
--]]

local Stats = {}

local DAY_PREFIX = "__wr:day:"
local TOTAL_ID = "__wr:total"
--- 旧版周排行合成行（record_type=book），已由单书按日取代；每次拉取顺手清掉。
local LEGACY_WEEK_PREFIX = "__wr:week:"

local function field(wire, key)
    if type(wire) ~= "table" then return nil end
    if wire[key] ~= nil then return wire[key] end
    return type(wire.data) == "table" and wire.data[key] or nil
end

--- 合成 reading_stats 行；云端没有页坐标，page/total_pages 恒为 0。
local function statsRow(source_id, stable_id, record_type, start_time, duration, last_time)
    return {
        source_id = source_id,
        stable_id = stable_id,
        record_type = record_type,
        page = 0,
        start_time = start_time,
        duration = duration,
        total_pages = 0,
        last_time = last_time,
    }
end

local function appendTimes(rows, source_id, read_times, fetched_at)
    if type(read_times) ~= "table" then return end
    for ts_str, seconds in pairs(read_times) do
        local ts = tonumber(ts_str)
        local duration = tonumber(seconds)
        if ts and duration and duration > 0 then
            rows[#rows + 1] = statsRow(source_id, DAY_PREFIX .. tostring(ts), "day", ts, duration, fetched_at)
        end
    end
end

local function yearRange(wire)
    local base_time = tonumber(field(wire, "baseTime")) or os.time()
    local year = assert(tonumber(os.date("%Y", base_time)))
    ---@cast year integer
    local from_ts = os.time({ year = year, month = 1, day = 1, hour = 0 })
    local to_ts = os.time({ year = year + 1, month = 1, day = 1, hour = 0 }) - 1
    return from_ts, to_ts
end

--- 从 overall 年桶得到需要逐年拉取的基准时间，始终包含当前年。
---@param overall table
---@return number[]
function Stats.annualBaseTimes(overall)
    local by_year = {}
    local read_times = field(overall, "readTimes")
    if type(read_times) == "table" then
        for ts_str in pairs(read_times) do
            local ts = tonumber(ts_str)
            if ts and ts > 0 then
                by_year[tonumber(os.date("%Y", ts))] = ts
            end
        end
    end
    local current_year = assert(tonumber(os.date("%Y")))
    ---@cast current_year integer
    by_year[current_year] = by_year[current_year]
        or os.time({ year = current_year, month = 1, day = 1, hour = 0 })
    local years = {}
    for year in pairs(by_year) do years[#years + 1] = year end
    table.sort(years)
    local out = {}
    for _, year in ipairs(years) do out[#out + 1] = by_year[year] end
    return out
end

--- 年度无日明细时，从月桶找出需要继续拉取的月份。
---@param annual table
---@return number[]
function Stats.monthlyBaseTimes(annual)
    local daily = field(annual, "dailyReadTimes")
    if type(daily) == "table" and next(daily) ~= nil then return {} end
    local out = {}
    local read_times = field(annual, "readTimes")
    if type(read_times) == "table" then
        for ts_str, seconds in pairs(read_times) do
            local ts = tonumber(ts_str)
            if ts and ts > 0 and (tonumber(seconds) or 0) > 0 then
                out[#out + 1] = ts
            end
        end
    end
    table.sort(out)
    return out
end

--- 书架 ``bookProgress`` 里云端累计与本地快照不同的书（即某台设备读过），最近更新的在前。
---@param progresses table[]|nil 书架 wire 的 bookProgress
---@param stored table<string, number> 本地 book_total 快照：bookId → 秒
---@param limit integer 本轮最多拉取的书数，其余留给下次同步
---@return { id: string, reading_time: number }[]
function Stats.changedBooks(progresses, stored, limit)
    local changed = {}
    for _, p in ipairs(type(progresses) == "table" and progresses or {}) do
        local seconds = tonumber(p.readingTime) or 0
        local id = p.bookId ~= nil and tostring(p.bookId) or nil
        if id and seconds ~= (stored[id] or 0) then
            changed[#changed + 1] = {
                id = id, reading_time = seconds, updated_at = tonumber(p.updateTime) or 0,
            }
        end
    end
    table.sort(changed, function(a, b) return a.updated_at > b.updated_at end)
    local out = {}
    for i = 1, math.min(limit, #changed) do
        out[i] = { id = changed[i].id, reading_time = changed[i].reading_time }
    end
    return out
end

--- 单书：书架累计快照 + readinfo 按日明细。
local function appendBook(rows, source_id, book, fetched_at)
    if book.reading_time > 0 then
        rows[#rows + 1] = statsRow(source_id, book.id, "book_total", fetched_at, book.reading_time)
    end
    local detail = field(book.wire, "readDetail")
    local days = type(detail) == "table" and detail.data or nil
    for _, day in ipairs(type(days) == "table" and days or {}) do
        local ts = tonumber(day.readDate)
        local seconds = tonumber(day.readTime)
        if ts and seconds and seconds > 0 then
            rows[#rows + 1] = statsRow(source_id, book.id, "book_day", ts, seconds, fetched_at)
        end
    end
end

--- 合并总体权威总量、账户日桶与单书明细。
---@param source_id string
---@param overall table
---@param annuals table[]
---@param monthlies table[]|nil
---@param books { id: string, reading_time: number, wire: table }[]|nil 已拉到 readinfo 的书
---@param fetched_at number|nil 拉取时间
---@return BookStatsPullResult
function Stats.fromWires(source_id, overall, annuals, monthlies, books, fetched_at)
    fetched_at = fetched_at or os.time()
    local rows = {}
    local total = tonumber(field(overall, "totalReadTime"))
    if total and total > 0 then
        rows[#rows + 1] = statsRow(source_id, TOTAL_ID, "total", 0, total)
    end
    local ranges = {
        { stable_prefix = TOTAL_ID, from_ts = 0, to_ts = 0 },
        { stable_prefix = LEGACY_WEEK_PREFIX, from_ts = 0, to_ts = fetched_at },
    }
    for _, annual in ipairs(annuals or {}) do
        -- 年度回包有真实日明细时直接使用；没有时由月度请求补齐。
        appendTimes(rows, source_id, field(annual, "dailyReadTimes"), fetched_at)
        local from_ts, to_ts = yearRange(annual)
        ranges[#ranges + 1] = {
            stable_prefix = DAY_PREFIX, from_ts = from_ts, to_ts = to_ts,
        }
    end
    for _, monthly in ipairs(monthlies or {}) do
        -- 月度 ``readTimes`` 的粒度是日，可以直接落日桶。
        appendTimes(rows, source_id, field(monthly, "readTimes"), fetched_at)
    end
    local book_ids = {}
    for _, book in ipairs(books or {}) do
        appendBook(rows, source_id, book, fetched_at)
        book_ids[#book_ids + 1] = book.id
    end
    return {
        rows = rows,
        replace = {
            mode = "ranges",
            ranges = ranges,
            books = book_ids,
        },
    }
end

Stats.TOTAL_ID = TOTAL_ID

return Stats
