--[[--
微信读书阅读统计：``/readdata/detail`` wire → reading_stats 领域行。

云端日桶用 ``__wr:day:<ts>``；周期内读书排行用 ``__wr:book:<id>:<baseTime>``。
入库前由 book.stats 按 replace.synced 清除旧已同步行，避免与本地页记录双计。

@module koplugin.book.source.wechat.stats
--]]

local Stats = {}

local DAY_PREFIX = "__wr:day:"
local BOOK_PREFIX = "__wr:book:"

--- 从 gateway 回包构造可入库统计行与替换策略。
---@param source_id string
---@param wire table|nil
---@return BookStatsPullResult
function Stats.fromWire(source_id, wire)
    local rows = {}
    wire = type(wire) == "table" and wire or {}
    local base_time = tonumber(wire.baseTime) or 0

    local read_times = wire.readTimes
    if type(read_times) ~= "table" and type(wire.data) == "table" then
        read_times = wire.data.readTimes
    end
    if type(read_times) == "table" then
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

    local read_longest = wire.readLongest
    if type(read_longest) ~= "table" and type(wire.data) == "table" then
        read_longest = wire.data.readLongest
    end
    if type(read_longest) == "table" then
        local anchor = base_time > 0 and base_time or 0
        for _, item in ipairs(read_longest) do
            if type(item) == "table" then
                local book = item.book or {}
                local id = book.bookId or book.id
                local duration = tonumber(item.readTime or item.readingTime)
                if id and duration and duration > 0 then
                    rows[#rows + 1] = {
                        source_id = source_id,
                        stable_id = BOOK_PREFIX .. tostring(id) .. ":" .. tostring(anchor),
                        record_type = "book",
                        page = 0,
                        start_time = anchor,
                        duration = duration,
                        total_pages = 0,
                    }
                end
            end
        end
    end

    return {
        rows = rows,
        replace = { mode = "synced" },
    }
end

Stats.DAY_PREFIX = DAY_PREFIX
Stats.BOOK_PREFIX = BOOK_PREFIX

return Stats
