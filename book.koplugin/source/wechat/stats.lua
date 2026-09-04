--[[--
微信读书阅读统计：累计总量 + 年度明细 wire → reading_stats 领域行。

云端只提供账户级日桶 ``__wr:day:<ts>``，不伪造按日书籍归属。
权威累计时长用 ``__wr:total``，不参与日历分桶求和。
入库前按各合成前缀的时间窗口替换旧记录，避免重复累计。

@module koplugin.book.source.wechat.stats
--]]

local Stats = {}

local DAY_PREFIX = "__wr:day:"
local LEGACY_BOOK_PREFIX = "__wr:book:"
local TOTAL_ID = "__wr:total"

local function field(wire, key)
    if type(wire) ~= "table" then return nil end
    if wire[key] ~= nil then return wire[key] end
    return type(wire.data) == "table" and wire.data[key] or nil
end

local function appendTimes(rows, source_id, read_times)
    if type(read_times) ~= "table" then return end
    for ts_str, seconds in pairs(read_times) do
        local ts = tonumber(ts_str)
        local duration = tonumber(seconds)
        if ts and duration and duration > 0 then
            rows[#rows + 1] = {
                source_id = source_id,
                stable_id = DAY_PREFIX .. tostring(ts),
                record_type = "day",
                page = 0,
                start_time = ts,
                duration = duration,
                total_pages = 0,
            }
        end
    end
end

--- 年度回包有真实日明细时直接使用；没有时由月度请求补齐。
local function appendAnnualDaily(rows, source_id, wire)
    appendTimes(rows, source_id, field(wire, "dailyReadTimes"))
end

--- 月度 ``readTimes`` 的粒度是日，可以直接落日桶。
local function appendMonthlyDaily(rows, source_id, wire)
    appendTimes(rows, source_id, field(wire, "readTimes"))
end

local function yearRange(wire)
    local base_time = tonumber(field(wire, "baseTime")) or os.time()
    local year = tonumber(os.date("%Y", base_time))
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
    local current_year = tonumber(os.date("%Y"))
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

--- 合并总体权威总量、年度日明细和月度日桶。
---@param source_id string
---@param overall table
---@param annuals table[]
---@param monthlies table[]|nil
---@return BookStatsPullResult
function Stats.fromWires(source_id, overall, annuals, monthlies)
    local rows = {}
    local total = tonumber(field(overall, "totalReadTime"))
    if total and total > 0 then
        rows[#rows + 1] = {
            source_id = source_id,
            stable_id = TOTAL_ID,
            record_type = "total",
            page = 0,
            start_time = 0,
            duration = total,
            total_pages = 0,
        }
    end
    local ranges = {
        { stable_prefix = TOTAL_ID, from_ts = 0, to_ts = 0 },
    }
    for _, annual in ipairs(annuals or {}) do
        appendAnnualDaily(rows, source_id, annual)
        local from_ts, to_ts = yearRange(annual)
        ranges[#ranges + 1] = {
            stable_prefix = DAY_PREFIX, from_ts = from_ts, to_ts = to_ts,
        }
        ranges[#ranges + 1] = {
            stable_prefix = LEGACY_BOOK_PREFIX, from_ts = from_ts, to_ts = to_ts,
        }
    end
    for _, monthly in ipairs(monthlies or {}) do
        appendMonthlyDaily(rows, source_id, monthly)
    end
    return {
        rows = rows,
        replace = {
            mode = "ranges",
            ranges = ranges,
        },
    }
end

Stats.DAY_PREFIX = DAY_PREFIX
Stats.TOTAL_ID = TOTAL_ID

return Stats
