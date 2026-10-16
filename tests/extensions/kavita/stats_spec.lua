--[[--
moonsource_kavita.stats：reading-history 条目 → reading_stats 行 / 替换指令 / 身份与时区映射。

对账基线 = research-kavita-stats-pull.md §3（样本 series 7453：64 条会话 / 14,237s）。

@module tests.extensions.kavita.stats_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")

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
    Assert.eq(#result.replace.ranges, 2)
    local day_range, total_range = result.replace.ranges[1], result.replace.ranges[2]
    if day_range.stable_prefix == "__kv:total" then day_range, total_range = total_range, day_range end
    Assert.eq(day_range.stable_prefix, "__kv:day:")
    Assert.eq(day_range.from_ts, 0)
    Assert.eq(day_range.to_ts, FETCHED)
    Assert.eq(total_range.stable_prefix, "__kv:total")
    Assert.eq(total_range.from_ts, 0)
    Assert.eq(total_range.to_ts, 0)
    -- 全量重拉的清理窗口必须盖住本次写出的每个日桶，否则消失的日桶会残留
    for _idx, row in ipairs(result.rows) do
        if row.record_type == "day" then
            Assert.is_true(row.start_time <= day_range.to_ts, "日桶落在清理窗口内")
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
    Assert.len(result.identities, 3)
    Assert.contains(result.identities, "55:11")
    Assert.contains(result.identities, "55:12")
    Assert.contains(result.identities, "66")
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
    Assert.eq(#empty.replace.ranges, 2)
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
