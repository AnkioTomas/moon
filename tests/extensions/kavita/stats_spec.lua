--[[--
moonsource_kavita.stats：reading-history 条目 → reading_stats 行 / 替换指令 / 身份与时区映射。

对账基线 = research-kavita-stats-pull.md §3（样本 series 7453：64 条会话 / 14,237s）。

@module tests.extensions.kavita.stats_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

-- 日 / 时归属按进程时区（POSIX TZ）计算：钉死 CST-8，与 fixture 拉取时用的 Asia/Shanghai 对齐，
-- 断言就不会随宿主机时区漂移。
local ffi = require("ffi")
ffi.cdef[[ int setenv(const char*, const char*, int); void tzset(void); ]]
ffi.C.setenv("TZ", "CST-8", 1)
ffi.C.tzset()

local warnings = {}
package.preload["utils.log"] = function()
    return {
        dbg = function() end,
        info = function() end,
        warn = function(...) warnings[#warnings + 1] = table.concat({ ... }, " ") end,
        error = function() end,
    }
end

local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"
package.preload["moonsource_kavita.stats"] = function()
    return dofile(PLUGIN .. "/moonsource_kavita/stats.lua")
end
local Stats = require("moonsource_kavita.stats")

-- 固定拉取时刻（2026-10-16T12:00:00Z，晚于样本最后一天）：last_time / book_total.start_time 都对它断言
local FETCHED = 1792152000

--- 当天设备本地零点。日期本身来自服务端；期望时差另有 research §3 表兜底。
local function dayTs(y, m, d)
    return os.time({ year = y, month = m, day = d, hour = 0 })
end

--- 当天设备本地整点（时段桶键）。
local function hourTs(y, m, d, h)
    return os.time({ year = y, month = m, day = d, hour = h })
end

--- 按记录身份找行（不依赖 rows 顺序）。
local function find(rows, record_type, stable_id, start_time)
    for _idx, row in ipairs(rows) do
        if row.record_type == record_type and row.stable_id == stable_id
            and (start_time == nil or row.start_time == start_time) then
            return row
        end
    end
end

--- 需要跨日断言时看日归属是否真是「服务端那一天」。
local function ymd(ts)
    return os.date("%Y-%m-%d", ts)
end

do
    -- 对账：样本《太空漫游 · 2010》64 条会话。逐日时长 / 页数为 research §3 的已知值。
    local history = dofile(Config.root() .. "/tests/extensions/kavita/fixtures/history_7453.lua")
    local result = Stats.fromHistory(history, {
        source_id = "ext.kavita",
        fetched_at = FETCHED,
        volumes = { [7453] = 4 },
        seen = { "7453:11270" },
    })

    local total = find(result.rows, "total", "__kv:total", 0)
    Assert.not_nil(total, "账户累计行必须存在")
    Assert.eq(total.duration, 14237, "样本全量时长")
    Assert.eq(total.last_time, FETCHED, "累计行 last_time = 拉取时刻")

    local days = {
        { 2026, 9, 29, 316, 2 },
        { 2026, 10, 5, 195, 0 },
        { 2026, 10, 7, 503, 0 },
        { 2026, 10, 8, 2036, 0 },
        { 2026, 10, 11, 512, 0 },
        { 2026, 10, 13, 979, 0 },
        { 2026, 10, 14, 6734, 0 }, -- 当天 +1 / -1 分属两条会话：先求和再钳制，相抵为净 0 页
        { 2026, 10, 15, 2962, 16 },
    }
    local day_rows = 0
    local day_sum = 0
    local day_ts = {}
    for _idx, d in ipairs(days) do
        local ts = dayTs(d[1], d[2], d[3])
        day_ts[ts] = true
        local row = find(result.rows, "day", "__kv:day:" .. ts, ts)
        Assert.not_nil(row, "缺少日桶 " .. d[1] .. "-" .. d[2] .. "-" .. d[3])
        Assert.eq(row.duration, d[4], "日桶时长 " .. ymd(ts))
        Assert.eq(row.event_count, d[5], "日桶页数增量 " .. ymd(ts))
        Assert.eq(row.last_time, FETCHED, "日桶 last_time = 拉取时刻")
        day_rows = day_rows + 1
        day_sum = day_sum + row.duration
    end
    Assert.eq(day_rows, 8, "只有有有效时长的日子落桶")
    Assert.eq(day_sum, 14237, "账户累计 = 各日之和")

    -- 时段桶：每条活动行按自己的本地起始小时归档（跨零点的活动行取小时、仍记在条目那天）。
    local hour_rows, hour_total = 0, 0
    local hour_by_day = {}
    for _idx, row in ipairs(result.rows) do
        if row.record_type == "hour" then
            hour_rows = hour_rows + 1
            hour_total = hour_total + row.duration
            Assert.eq(row.stable_id, "__kv:hour:" .. row.start_time, "时段桶按整点做身份")
            Assert.eq(row.last_time, FETCHED, "时段桶 last_time = 拉取时刻")
            local d = os.date("%Y-%m-%d", row.start_time)
            hour_by_day[d] = (hour_by_day[d] or 0) + row.duration
        end
    end
    Assert.eq(hour_rows, 27, "样本 27 个整点有阅读")
    Assert.eq(hour_total, 14237, "时段之和 = 账户累计")
    Assert.eq(find(result.rows, "hour", "__kv:hour:" .. hourTs(2026, 10, 14, 11)).duration, 1352, "10-14 11 点")
    Assert.eq(find(result.rows, "hour", "__kv:hour:" .. hourTs(2026, 10, 14, 14)).duration, 1812, "10-14 14 点")
    Assert.eq(find(result.rows, "hour", "__kv:hour:" .. hourTs(2026, 9, 29, 18)).duration, 316, "9-29 18 点")
    Assert.eq(find(result.rows, "hour", "__kv:hour:" .. hourTs(2026, 10, 15, 21)).duration, 845, "10-15 21 点")
    -- 日页面「标题时长 = 时段图逐格之和」：逐日必须对得上
    for _idx, d in ipairs(days) do
        Assert.eq(hour_by_day[ymd(dayTs(d[1], d[2], d[3]))], d[4],
            "时段逐日之和 = 日桶 " .. d[1] .. "-" .. d[2] .. "-" .. d[3])
    end
    -- 零时长会话（10-06 的 4 条等）整条丢弃，不留日桶
    for _idx, d in ipairs({ { 2026, 10, 6 }, { 2026, 10, 9 }, { 2026, 10, 10 }, { 2026, 10, 12 } }) do
        local ts = dayTs(d[1], d[2], d[3])
        Assert.is_nil(find(result.rows, "day", "__kv:day:" .. ts, ts), "零时长日不留桶")
    end

    -- 多卷系列：章节 4 卷 → 逐卷身份；11271 只在 9-29 读过，11273 是其余各日。
    local book_total = find(result.rows, "book_total", "7453:11273", FETCHED)
    Assert.not_nil(book_total, "卷累计行")
    Assert.eq(book_total.duration, 13921)
    Assert.eq(find(result.rows, "book_total", "7453:11271", FETCHED).duration, 316)

    Assert.eq(find(result.rows, "book_day", "7453:11271", dayTs(2026, 9, 29)).duration, 316)
    local book_days, book_totals = 0, 0
    for _idx, row in ipairs(result.rows) do
        if row.record_type == "book_day" then
            book_days = book_days + 1
            Assert.is_true(row.duration > 0, "单书日行也必须正时长")
            Assert.is_true(day_ts[row.start_time] == true, "单书日行 start_time = 服务端那天的本地零点")
        elseif row.record_type == "book_total" then
            book_totals = book_totals + 1
            Assert.eq(row.start_time, FETCHED, "单书累计行的 start_time = 拉取时刻")
        end
        -- 云端快照没有页坐标，所有行 page / total_pages 恒为 0
        Assert.eq(row.page, 0, "云端行 page=0")
        Assert.eq(row.total_pages, 0, "云端行 total_pages=0")
        Assert.eq(row.source_id, "ext.kavita")
    end
    Assert.eq(book_days, 8, "11271 一天 + 11273 七天")
    Assert.eq(book_totals, 2, "每卷一条累计快照")

    -- 本次身份：持久化后下次当「上次身份」用于清孤儿行。
    Assert.eq(#result.identities, 2)
    Assert.contains(result.identities, "7453:11271")
    Assert.contains(result.identities, "7453:11273")

    -- 替换：账户桶按前缀 + 覆盖全量重拉窗口的时间窗；单书按上次 ∪ 本次身份精确清。
    Assert.eq(result.replace.mode, "ranges")
    Assert.eq(#result.replace.ranges, 3)
    local ranges = {}
    for _idx, range in ipairs(result.replace.ranges) do ranges[range.stable_prefix] = range end
    local day_range, hour_range, total_range =
        ranges["__kv:day:"], ranges["__kv:hour:"], ranges["__kv:total"]
    Assert.not_nil(day_range, "日桶清理范围")
    Assert.not_nil(hour_range, "时段桶清理范围")
    Assert.not_nil(total_range, "总量行清理范围")
    Assert.eq(day_range.from_ts, 0)
    Assert.eq(day_range.to_ts, FETCHED)
    Assert.eq(hour_range.from_ts, 0)
    Assert.eq(hour_range.to_ts, FETCHED)
    Assert.eq(total_range.from_ts, 0)
    Assert.eq(total_range.to_ts, 0)
    -- 全量重拉的清理窗口必须盖住本次写出的每个桶，否则消失的桶会残留
    for _idx, row in ipairs(result.rows) do
        if row.record_type == "day" then
            Assert.is_true(row.start_time <= day_range.to_ts, "日桶落在清理窗口内")
        elseif row.record_type == "hour" then
            Assert.is_true(row.start_time <= hour_range.to_ts, "时段桶落在清理窗口内")
        end
    end
    Assert.eq(#result.replace.books, 3, "上次身份 ∪ 本次身份（含漂移孤儿）")
    Assert.contains(result.replace.books, "7453:11270")
    Assert.contains(result.replace.books, "7453:11271")
    Assert.contains(result.replace.books, "7453:11273")
end

do
    -- 多章会话（跨卷）按章拆到各卷；单卷系列读在 series 行（research §5 的身份约定）。
    local result = Stats.fromHistory({
        { seriesId = 55, localDate = "2026-10-10T00:00:00", chapters = {
            { chapterId = 11, durationSeconds = 100, pagesRead = 2 },
            { chapterId = 12, durationSeconds = 50, pagesRead = -1 },
        } },
        { seriesId = 66, localDate = "2026-10-10T00:00:00", chapters = {
            { chapterId = 21, durationSeconds = 70, pagesRead = 0 },
        } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [55] = 2, [66] = 1 } })
    local day = dayTs(2026, 10, 10)
    Assert.eq(find(result.rows, "book_day", "55:11", day).duration, 100)
    Assert.eq(find(result.rows, "book_day", "55:12", day).duration, 50)
    Assert.eq(find(result.rows, "book_day", "66", day).duration, 70, "单卷记 series 身份")
    Assert.eq(find(result.rows, "book_total", "55:11", 2000).duration, 100)
    Assert.eq(find(result.rows, "book_total", "66", 2000).duration, 70)
    local day_row = find(result.rows, "day", "__kv:day:" .. day, day)
    Assert.eq(day_row.duration, 220, "账户日是各章之和")
    Assert.eq(day_row.event_count, 1, "当天页数先求和：2 + (-1) + 0")
    Assert.eq(find(result.rows, "total", "__kv:total", 0).duration, 220)
    -- 没有 startTimeUtc 的条目退回 localDate 分日；造不出小时就不造，绝不凭空补一个整点。
    for _idx, row in ipairs(result.rows) do
        Assert.is_true(row.record_type ~= "hour", "缺 startTimeUtc 不造时段桶")
    end
    Assert.len(result.identities, 3)
    Assert.contains(result.identities, "55:11")
    Assert.contains(result.identities, "55:12")
    Assert.contains(result.identities, "66")
end

do
    -- 分日 / 分时按服务端 UTC 时刻在设备本地（CST-8）换算，不信服务端按请求时区给的 localDate。
    local result = Stats.fromHistory({
        -- 本地 10-16 07:59（UTC 10-15 23:59）：服务端若按 UTC 算 localDate 会给 10-15，差一天。
        { seriesId = 31, startTimeUtc = "2026-10-15T23:59:00.1", localDate = "2026-10-15T00:00:00",
            chapters = { { chapterId = 1, startTimeUtc = "2026-10-15T23:59:00.1", durationSeconds = 60, pagesRead = 1 } } },
        -- 本地 10-17 00:30 起、23:50 又读了一段：日桶在 10-17，两个时段格也都算 10-17 这天。
        { seriesId = 32, startTimeUtc = "2026-10-16T16:30:00", localDate = "2026-10-17T00:00:00",
            chapters = {
                { chapterId = 1, startTimeUtc = "2026-10-16T16:30:00", durationSeconds = 40, pagesRead = 0 },
                { chapterId = 1, startTimeUtc = "2026-10-17T15:50:00", durationSeconds = 60, pagesRead = 0 },
            } },
    }, { source_id = "ext.kavita", fetched_at = FETCHED, volumes = { [31] = 2, [32] = 2, [33] = 2 } })
    local d16, d17 = dayTs(2026, 10, 16), dayTs(2026, 10, 17)
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d16, d16).duration, 60, "本地 07:59 落本地当天")
    Assert.eq(find(result.rows, "hour", "__kv:hour:" .. hourTs(2026, 10, 16, 7)).duration, 60, "本地 7 点格")
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d17, d17).duration, 100, "本地 0:30 起的那条落 10-17")
    Assert.eq(find(result.rows, "hour", "__kv:hour:" .. hourTs(2026, 10, 17, 0)).duration, 40, "0 点格")
    Assert.eq(find(result.rows, "hour", "__kv:hour:" .. hourTs(2026, 10, 17, 23)).duration, 60, "23 点格")
    Assert.is_nil(find(result.rows, "hour", "__kv:hour:" .. hourTs(2026, 10, 18, 0)),
        "跨零点前的活动行不另起一天")
end

do
    -- 负页数：按天先求和再钳制。逐条钳制会让 +5 / -5 相抵的日子凭空多出 5 页。
    local d1, d2 = dayTs(2026, 10, 1), dayTs(2026, 10, 2)
    local result = Stats.fromHistory({
        { seriesId = 7, localDate = "2026-10-01T00:00:00", chapters = {
            { chapterId = 1, durationSeconds = 10, pagesRead = 5 } } },
        { seriesId = 7, localDate = "2026-10-01T00:00:00", chapters = {
            { chapterId = 1, durationSeconds = 10, pagesRead = -5 } } },
        { seriesId = 7, localDate = "2026-10-02T00:00:00", chapters = {
            { chapterId = 1, durationSeconds = 10, pagesRead = -3 },
            { chapterId = 1, durationSeconds = 10, pagesRead = -4 } } },
    }, { source_id = "ext.kavita", fetched_at = 3000, volumes = { [7] = 2 } })
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d1, d1).event_count, 0, "正负相抵为净 0")
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d2, d2).event_count, 0, "负和钳制到 0")
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d1, d1).duration, 20)
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d2, d2).duration, 20)
end

do
    -- 时区回退（UTC）下服务端的「日」可能晚于设备本地的拉取时刻（设备为负偏移）：
    -- 日桶清理窗口的上界要盖到最后观测日的日终，否则当天桶清不掉，会残留到下一轮。
    local last_day = dayTs(2026, 10, 16)
    local fetched = last_day - 600 -- 设备本地 23:50，比最后观测日的零点还早
    local result = Stats.fromHistory({
        { seriesId = 21, localDate = "2026-10-16T00:00:00",
            chapters = { { chapterId = 1, durationSeconds = 300, pagesRead = 1 } } },
    }, { source_id = "ext.kavita", fetched_at = fetched, volumes = { [21] = 2 } })
    local day_range
    for _idx, range in ipairs(result.replace.ranges) do
        if range.stable_prefix == "__kv:day:" then day_range = range end
    end
    Assert.not_nil(day_range)
    Assert.eq(day_range.from_ts, 0, "窗口下界仍是 0（全量重拉）")
    Assert.eq(day_range.to_ts, last_day + 86399, "上界盖到最后观测日的日终")
    for _idx, row in ipairs(result.rows) do
        if row.record_type == "day" then
            Assert.is_true(row.start_time <= day_range.to_ts, "日桶落在清理窗口内")
        end
    end
    Assert.eq(day_range.stable_prefix:sub(1, 5), "__kv:", "范围只匹配本源的合成行，本地记录不受影响")
end

do
    -- 零时长条目整条丢弃（连页数一起）：Kavita 会给「打开没读」建 0 时长会话。
    -- 本次身份照交回，好让 replace.books 清掉它上次留下的行。
    local d = dayTs(2026, 10, 3)
    local before = #warnings
    local result = Stats.fromHistory({
        { seriesId = 8, localDate = "2026-10-03T00:00:00", chapters = {
            { chapterId = 1, durationSeconds = 0, pagesRead = 9 } } },
        { seriesId = 8, localDate = "2026-10-03T00:00:00", chapters = {
            { chapterId = 1, durationSeconds = 60, pagesRead = 0 } } },
        -- 目录拿不到章数的系列判不出身份：整体跳过，不猜单卷 / 多卷
        { seriesId = 999, localDate = "2026-10-03T00:00:00", chapters = {
            { chapterId = 1, durationSeconds = 100, pagesRead = 1 } } },
    }, { source_id = "ext.kavita", fetched_at = 4000, volumes = { [8] = 2 }, seen = { "8:1" } })
    Assert.eq(find(result.rows, "book_day", "8:1", d).duration, 60)
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d, d).event_count, 0, "零时长条目的页数不算")
    Assert.eq(find(result.rows, "total", "__kv:total", 0).duration, 60, "跳过的系列不进总量")
    Assert.eq(#result.identities, 1)
    Assert.contains(result.identities, "8:1")
    Assert.eq(#result.replace.books, 1)
    Assert.contains(result.replace.books, "8:1")
    local mentioned = false
    for i = before + 1, #warnings do
        if warnings[i]:find("999", 1, true) then mentioned = true end
    end
    Assert.is_true(mentioned, "跳过的系列要能被日志定位")

    -- 空回包不炸：仍给出完整的替换指令（全量重拉窗口照旧清）
    local empty = Stats.fromHistory(nil, { source_id = "ext.kavita", fetched_at = 4000 })
    Assert.len(empty.rows, 0)
    Assert.len(empty.identities, 0)
    Assert.len(empty.replace.books, 0)
    Assert.eq(#empty.replace.ranges, 3)
end

do
    -- seen 的重复 / 空串不进 books；并集按 stable_id 精确去重（4 / 42 互为前缀，不能用 LIKE）
    local result = Stats.fromHistory({
        { seriesId = 9, localDate = "2026-10-04T00:00:00", chapters = {
            { chapterId = 1, durationSeconds = 5, pagesRead = 0 } } },
    }, { source_id = "ext.kavita", fetched_at = 5000, volumes = { [9] = 2 },
        seen = { "9:1", "", "9:1", "stale" } })
    Assert.eq(#result.replace.books, 2)
    Assert.contains(result.replace.books, "9:1")
    Assert.contains(result.replace.books, "stale")
end

do
    -- 时区映射全表：设备时钟的 19 项 POSIX 串 → IANA（Kavita 的 TimeZoneId）
    local expected = {
        ["HST10"] = "Pacific/Honolulu",
        ["AKST9AKDT,M3.2.0,M11.1.0"] = "America/Anchorage",
        ["PST8PDT,M3.2.0,M11.1.0"] = "America/Los_Angeles",
        ["MST7MDT,M3.2.0,M11.1.0"] = "America/Denver",
        ["CST6CDT,M3.2.0,M11.1.0"] = "America/Chicago",
        ["EST5EDT,M3.2.0,M11.1.0"] = "America/New_York",
        ["<-03>3"] = "America/Sao_Paulo",
        ["UTC0"] = "UTC",
        ["GMT0BST,M3.5.0/1,M10.5.0"] = "Europe/London",
        ["CET-1CEST,M3.5.0,M10.5.0/3"] = "Europe/Berlin",
        ["EET-2EEST,M3.5.0/3,M10.5.0/4"] = "Europe/Athens",
        ["MSK-3"] = "Europe/Moscow",
        ["<+04>-4"] = "Asia/Dubai",
        ["IST-5:30"] = "Asia/Kolkata",
        ["<+07>-7"] = "Asia/Bangkok",
        ["CST-8"] = "Asia/Shanghai",
        ["JST-9"] = "Asia/Tokyo",
        ["AEST-10AEDT,M10.1.0,M4.1.0/3"] = "Australia/Sydney",
        ["NZST-12NZDT,M9.5.0,M4.1.0/3"] = "Pacific/Auckland",
    }
    local n = 0
    for posix, iana in pairs(expected) do
        n = n + 1
        Assert.eq(Stats.ianaTimezone(posix), iana, posix)
    end
    Assert.eq(n, 19)

    -- 与设置页的时区表保持同步（读源码不 require UI 依赖）：时钟加项时必须同步映射
    local file = assert(io.open(Config.root() .. "/book.koplugin/features/clock/init.lua", "r"))
    local source = file:read("*a")
    file:close()
    local in_block, covered = false, 0
    for line in source:gmatch("[^\n]+") do
        if line:match("Clock%.TIMEZONES%s*=") then
            in_block = true
        elseif in_block then
            if line:match("^}") then break end
            local posix = line:match('tz%s*=%s*"([^"]*)"')
            if posix and posix ~= "" then
                covered = covered + 1
                Assert.not_nil(expected[posix], "时钟时区缺少 IANA 映射：" .. posix)
            end
        end
    end
    Assert.eq(covered, 19, "时钟时区表全部覆盖")

    -- 未知 / 空串（跟随系统）回退 UTC 并 warn，不做地区默认
    local before = #warnings
    Assert.eq(Stats.ianaTimezone(""), "UTC")
    Assert.eq(Stats.ianaTimezone("NOPE-1"), "UTC")
    Assert.eq(Stats.ianaTimezone(nil), "UTC")
    Assert.eq(#warnings, before + 3, "每次回退都记一条日志")
end

do
    -- 阅读会话行：每个「会话 × 章」切片的真实起始时刻 / 时长 / 页数，供详情「阅读记录」列出时段。
    -- 它只进列表，不参与日 / 时段 / 总量汇总。
    local day = dayTs(2026, 10, 10)
    local result = Stats.fromHistory({
        { seriesId = 66, startTimeUtc = "2026-10-10T09:00:00.0000000", chapters = {
            { chapterId = 1, durationSeconds = 600, pagesRead = 12,
              startTimeUtc = "2026-10-10T09:00:00.0000000" },
            { chapterId = 2, durationSeconds = 300, pagesRead = 3,
              startTimeUtc = "2026-10-10T09:20:00.0000000" },
        } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [66] = 1 } })

    local first = find(result.rows, "cloud_session", "66", hourTs(2026, 10, 10, 17))
    Assert.not_nil(first, "会话行按章切片的本地起始时刻落行")
    Assert.eq(first.duration, 600)
    Assert.eq(first.event_count, 12, "页数记在 event_count")
    Assert.eq(first.last_time, 2000, "会话行 last_time = 拉取时刻")
    local second = find(result.rows, "cloud_session", "66", hourTs(2026, 10, 10, 17) + 20 * 60)
    Assert.not_nil(second)
    Assert.eq(second.duration, 300)
    Assert.eq(second.event_count, 3)

    -- 会话行不影响任何汇总桶：日桶 / 总量仍是 900，且不会多出 hour 之外的重复
    Assert.eq(find(result.rows, "day", "__kv:day:" .. day, day).duration, 900)
    Assert.eq(find(result.rows, "total", "__kv:total", 0).duration, 900)
    Assert.eq(find(result.rows, "book_day", "66", day).duration, 900)

    -- 零时长会话不落会话行
    local zero = Stats.fromHistory({
        { seriesId = 66, startTimeUtc = "2026-10-10T10:00:00.0000000", chapters = {
            { chapterId = 1, durationSeconds = 0, pagesRead = 0,
              startTimeUtc = "2026-10-10T10:00:00.0000000" },
        } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [66] = 1 } })
    Assert.is_nil(find(zero.rows, "cloud_session", "66"), "打开没读的会话不落行")
end

do
    -- 漫画（seriesFormat 0 Image / 1 Archive）的会话行补真实页坐标：page = endPage（读到哪）、
    -- total_pages = chapter.totalPages（卷级，汇总处继续 MAX）；event_count 是**本次新推进的页数**
    -- （不是 pagesRead —— 重读会重复计入，见下方进度用例）。pagesRead = 0 是合法值，不是缺数据。
    local result = Stats.fromHistory({
        { seriesId = 70, seriesFormat = 0, startTimeUtc = "2026-10-10T09:00:00.0000000", chapters = {
            { chapterId = 1, durationSeconds = 300, pagesRead = 12, startPage = 3, endPage = 15,
              totalPages = 194, startTimeUtc = "2026-10-10T09:00:00.0000000" },
        } },
        -- Archive 同样算漫画；同一系列两卷各自的卷级总页数不同，不能被条目级 totalPages 抹平。
        { seriesId = 71, seriesFormat = 1, startTimeUtc = "2026-10-10T10:00:00.0000000", chapters = {
            { chapterId = 2, durationSeconds = 60, pagesRead = 0, startPage = 1, endPage = 1,
              totalPages = 40, startTimeUtc = "2026-10-10T10:00:00.0000000" },
            { chapterId = 3, durationSeconds = 90, pagesRead = 7, startPage = 20, endPage = 30,
              totalPages = 52, startTimeUtc = "2026-10-10T10:30:00.0000000" },
        } },
        -- epub 的 Chapter.Pages 是 spine 数、与渲染页无关：页坐标保持 0，不因带 endPage 就填。
        { seriesId = 72, seriesFormat = 3, startTimeUtc = "2026-10-10T11:00:00.0000000", chapters = {
            { chapterId = 4, durationSeconds = 600, pagesRead = 7, startPage = 15, endPage = 15,
              totalPages = 22, startTimeUtc = "2026-10-10T11:00:00.0000000" },
        } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [70] = 1, [71] = 1, [72] = 1 } })

    local image = find(result.rows, "cloud_session", "70", hourTs(2026, 10, 10, 17))
    Assert.not_nil(image, "Image 漫画的会话行")
    Assert.eq(image.page, 15, "page = chapter.endPage")
    Assert.eq(image.total_pages, 194, "total_pages = chapter.totalPages")
    Assert.eq(image.event_count, 15, "event_count = 本次新推进的页数（0 → 15）")

    local archive_zero = find(result.rows, "cloud_session", "71", hourTs(2026, 10, 10, 18))
    Assert.not_nil(archive_zero, "Archive 漫画的会话行")
    Assert.eq(archive_zero.page, 1, "page = endPage（未翻页也合法）")
    Assert.eq(archive_zero.total_pages, 40, "卷级总页数")
    Assert.eq(archive_zero.event_count, 1, "推进到第 1 页即 1 页，与 pagesRead = 0 无关")
    local archive_more = find(result.rows, "cloud_session", "71", hourTs(2026, 10, 10, 18) + 30 * 60)
    Assert.not_nil(archive_more, "同一条目里的第二卷")
    Assert.eq(archive_more.page, 30)
    Assert.eq(archive_more.total_pages, 52, "逐章取自己的卷级总页数")
    Assert.eq(archive_more.event_count, 29, "1 → 30 只推进 29 页（不是 pagesRead 7）")

    local epub = find(result.rows, "cloud_session", "72", hourTs(2026, 10, 10, 19))
    Assert.not_nil(epub, "epub 的会话行照旧落")
    Assert.eq(epub.page, 0, "epub 不填 page")
    Assert.eq(epub.total_pages, 0, "epub 不填 total_pages")
    Assert.eq(epub.event_count, 7, "epub 仍用 pagesRead")

    -- 页坐标只加在会话行上：日 / 单书桶维持「云端快照没有页坐标」的语义（汇总另算）。
    local day = dayTs(2026, 10, 10)
    for _idx, row in ipairs(result.rows) do
        if row.record_type ~= "cloud_session" then
            Assert.eq(row.page, 0, row.record_type .. " 行 page 仍为 0")
            Assert.eq(row.total_pages, 0, row.record_type .. " 行 total_pages 仍为 0")
        end
    end
    -- 当天页数 = 15（70）+ 1（71 卷 2）+ 29（71 卷 3）+ 7（epub 仍是 pagesRead）
    Assert.eq(find(result.rows, "day", "__kv:day:" .. day, day).event_count, 52)
    Assert.eq(find(result.rows, "book_day", "70", day).duration, 300)
end

do
    -- 漫画的已读页数按「最远进度」算，不按页次累加：pagesRead 是「这次翻了多少页」，
    -- 重读会重复计入（实测 194 页的卷 6 条会话 pagesRead 合计 284，已读页数超过了总页数）。
    -- 样本：大剑 Vol.10，总 194 页；依次读到 3 → 91 → 42（重读）→ 94 → 126 → 194。
    local sessions = {
        { end_page = 3,   pages_read = 3 },
        { end_page = 91,  pages_read = 87 },
        { end_page = 42,  pages_read = 42 },
        { end_page = 94,  pages_read = 48 },
        { end_page = 126, pages_read = 34 },
        { end_page = 194, pages_read = 70 },
    }
    local expected = { 3, 88, 0, 3, 32, 68 } -- 每次都只是「比此前更远」的那一段；合计 194

    local function history()
        local entries = {}
        for i, s in ipairs(sessions) do
            -- UTC 01..06 点 → 本地（CST-8）09..14 点，同一本地的天。
            local utc = string.format("2026-10-10T%02d:00:00", i)
            entries[#entries + 1] = { seriesId = 100, seriesFormat = 0, startTimeUtc = utc, chapters = {
                { chapterId = 1, durationSeconds = 60, pagesRead = s.pages_read, startPage = 0,
                  endPage = s.end_page, totalPages = 194, startTimeUtc = utc } } }
        end
        return entries
    end

    local day = dayTs(2026, 10, 10)
    local function check(entries, label)
        local result = Stats.fromHistory(entries,
            { source_id = "ext.kavita", fetched_at = 2000, volumes = { [100] = 1 } })
        local sum = 0
        local session_rows = 0
        for _idx, row in ipairs(result.rows) do
            if row.record_type == "cloud_session" and row.stable_id == "100" then
                session_rows = session_rows + 1
            end
        end
        Assert.eq(session_rows, #sessions, label .. "：每条有时长的会话各落一行，不多不少")
        for i, want in ipairs(expected) do
            local row = find(result.rows, "cloud_session", "100", hourTs(2026, 10, 10, 8 + i))
            Assert.not_nil(row, label .. "：第 " .. i .. " 条会话行")
            Assert.eq(row.event_count, want, label .. "：第 " .. i .. " 条只算新推进的页数")
            -- 重读（第 3 条 endPage 42 < 已到达 91）页数为 0，但 page 仍如实记 42。
            Assert.eq(row.page, sessions[i].end_page, label .. "：第 " .. i .. " 条 page 仍记 endPage")
            Assert.eq(row.total_pages, 194, label .. "：第 " .. i .. " 条卷级总页数")
            sum = sum + row.event_count
        end
        Assert.eq(sum, 194, label .. "：合计 = 读到的最远页码 = 总页数")
        Assert.eq(find(result.rows, "day", "__kv:day:" .. day, day).event_count, 194,
            label .. "：当天页数也是进度而不是页次")
    end

    check(history(), "正序")
    -- 回包可能是新→旧：按章起始时刻排序，结果不受遍历顺序影响。
    local reversed = {}
    local forward = history()
    for i = #forward, 1, -1 do reversed[#reversed + 1] = forward[i] end
    check(reversed, "倒序")
end

do
    -- durationSeconds = 0 的跳页（只有 pagesRead / endPage、没有阅读时间）不发行 —— 会话行说的是
    -- 「读了多久」；但它要参与进度序列与当天页数，否则这段跳读会从当天页面消失、
    -- 而后续会话又因为 reached 更高而少算，合计就对不上读到的最远页码。
    local d = dayTs(2026, 10, 11)
    local result = Stats.fromHistory({
        { seriesId = 101, seriesFormat = 0, startTimeUtc = "2026-10-11T02:00:00", chapters = {
            { chapterId = 1, durationSeconds = 0, pagesRead = 20, startPage = 5, endPage = 60,
              totalPages = 100, startTimeUtc = "2026-10-11T02:00:00" } } },
        { seriesId = 101, seriesFormat = 0, startTimeUtc = "2026-10-11T03:00:00", chapters = {
            { chapterId = 1, durationSeconds = 120, pagesRead = 5, startPage = 60, endPage = 70,
              totalPages = 100, startTimeUtc = "2026-10-11T03:00:00" } } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [101] = 1 } })

    Assert.is_nil(find(result.rows, "cloud_session", "101", hourTs(2026, 10, 11, 10)),
        "零时长章行不发行会话行")
    local read = find(result.rows, "cloud_session", "101", hourTs(2026, 10, 11, 11))
    Assert.not_nil(read)
    Assert.eq(read.event_count, 10, "跳读已把进度推到 60，本次只推进 10 页")
    Assert.eq(read.page, 70)
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d, d).event_count, 70,
        "当天页数 = 最远页码（含零时长跳读推进的 60）")

    -- 登记身份用于清孤儿行：零时长条目照旧算见过（它上次可能留下过行）。
    Assert.contains(result.identities, "101")
end

do
    -- endPage 超过总页数（不同版本页数不一致）时钳到总页数：已读页数不可能超过总页数。
    local d = dayTs(2026, 10, 12)
    local result = Stats.fromHistory({
        { seriesId = 102, seriesFormat = 1, startTimeUtc = "2026-10-12T02:00:00", chapters = {
            { chapterId = 1, durationSeconds = 60, pagesRead = 40, startPage = 0, endPage = 250,
              totalPages = 194, startTimeUtc = "2026-10-12T02:00:00" } } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [102] = 1 } })
    local row = find(result.rows, "cloud_session", "102", hourTs(2026, 10, 12, 10))
    Assert.not_nil(row)
    Assert.eq(row.event_count, 194, "推进钳到总页数")
    Assert.eq(row.total_pages, 194)
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d, d).event_count, 194, "当天页数也被钳")

    -- 拿不到总页数（totalPages = 0 / 缺字段）时不假设上界：按 endPage 原样算。
    local unknown = Stats.fromHistory({
        { seriesId = 103, seriesFormat = 0, startTimeUtc = "2026-10-12T05:00:00", chapters = {
            { chapterId = 1, durationSeconds = 60, pagesRead = 9, endPage = 77,
              startTimeUtc = "2026-10-12T05:00:00" } } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [103] = 1 } })
    local no_total = find(unknown.rows, "cloud_session", "103", hourTs(2026, 10, 12, 13))
    Assert.not_nil(no_total)
    Assert.eq(no_total.event_count, 77, "缺总页数就照 endPage 算")
    Assert.eq(no_total.total_pages, 0)
end

do
    -- 多卷：每卷（stable_id = seriesId:chapterId）各自从 0 起算进度，互不影响；
    -- 合计 = 各卷进度之和（≤ 各卷总页数之和）。
    local d = dayTs(2026, 10, 13)
    local result = Stats.fromHistory({
        { seriesId = 80, seriesFormat = 0, startTimeUtc = "2026-10-13T02:00:00", chapters = {
            { chapterId = 1, durationSeconds = 60, pagesRead = 10, endPage = 10, totalPages = 40,
              startTimeUtc = "2026-10-13T02:00:00" } } },
        { seriesId = 80, seriesFormat = 0, startTimeUtc = "2026-10-13T03:00:00", chapters = {
            { chapterId = 1, durationSeconds = 60, pagesRead = 20, endPage = 30, totalPages = 40,
              startTimeUtc = "2026-10-13T03:00:00" } } },
        { seriesId = 80, seriesFormat = 0, startTimeUtc = "2026-10-13T04:00:00", chapters = {
            { chapterId = 2, durationSeconds = 60, pagesRead = 5, endPage = 5, totalPages = 60,
              startTimeUtc = "2026-10-13T04:00:00" } } },
        { seriesId = 80, seriesFormat = 0, startTimeUtc = "2026-10-13T05:00:00", chapters = {
            { chapterId = 2, durationSeconds = 60, pagesRead = 45, endPage = 50, totalPages = 60,
              startTimeUtc = "2026-10-13T05:00:00" } } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [80] = 2 } })

    Assert.eq(find(result.rows, "cloud_session", "80:1", hourTs(2026, 10, 13, 10)).event_count, 10)
    Assert.eq(find(result.rows, "cloud_session", "80:1", hourTs(2026, 10, 13, 11)).event_count, 20)
    Assert.eq(find(result.rows, "cloud_session", "80:2", hourTs(2026, 10, 13, 12)).event_count, 5)
    Assert.eq(find(result.rows, "cloud_session", "80:2", hourTs(2026, 10, 13, 13)).event_count, 45)
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d, d).event_count, 80, "10 + 20 + 5 + 45")
    Assert.eq(find(result.rows, "cloud_session", "80:1", hourTs(2026, 10, 13, 10)).total_pages, 40)
    Assert.eq(find(result.rows, "cloud_session", "80:2", hourTs(2026, 10, 13, 13)).total_pages, 60)
end

do
    -- epub / PDF 不受进度口径影响：pagesRead 照旧累加（重读同一页也算，这是「翻页数」语义），
    -- 页坐标仍为 0。
    local d = dayTs(2026, 10, 14)
    local result = Stats.fromHistory({
        { seriesId = 202, seriesFormat = 3, startTimeUtc = "2026-10-14T02:00:00", chapters = {
            { chapterId = 1, durationSeconds = 60, pagesRead = 7, startPage = 15, endPage = 15,
              totalPages = 22, startTimeUtc = "2026-10-14T02:00:00" } } },
        { seriesId = 202, seriesFormat = 3, startTimeUtc = "2026-10-14T03:00:00", chapters = {
            { chapterId = 1, durationSeconds = 60, pagesRead = 7, startPage = 15, endPage = 15,
              totalPages = 22, startTimeUtc = "2026-10-14T03:00:00" } } },
        -- PDF（4）同样不是渲染页，口径与 epub 一致。
        { seriesId = 203, seriesFormat = 4, startTimeUtc = "2026-10-14T04:00:00", chapters = {
            { chapterId = 1, durationSeconds = 60, pagesRead = 4, endPage = 99,
              totalPages = 120, startTimeUtc = "2026-10-14T04:00:00" } } },
    }, { source_id = "ext.kavita", fetched_at = 2000, volumes = { [202] = 1, [203] = 1 } })

    local first = find(result.rows, "cloud_session", "202", hourTs(2026, 10, 14, 10))
    local again = find(result.rows, "cloud_session", "202", hourTs(2026, 10, 14, 11))
    Assert.eq(first.event_count, 7, "epub 仍是 pagesRead")
    Assert.eq(again.event_count, 7, "epub 重读不折成 0（不是进度口径）")
    Assert.eq(first.page, 0)
    Assert.eq(first.total_pages, 0)
    local pdf = find(result.rows, "cloud_session", "203", hourTs(2026, 10, 14, 12))
    Assert.eq(pdf.event_count, 4, "PDF 仍是 pagesRead")
    Assert.eq(pdf.page, 0)
    Assert.eq(pdf.total_pages, 0)
    Assert.eq(find(result.rows, "day", "__kv:day:" .. d, d).event_count, 18, "7 + 7 + 4")
end
