--[[--
Kavita 阅读统计纯核心：reading-history 条目 + 身份 / 时区上下文 → reading_stats 行与替换指令。

条目是「会话 × 系列」切片。日归属直接用服务端在请求时区下给出的 `localDate`，不按会话起始
时刻自行分桶：两种时区对不上时，自行分桶会把时长挪到别的日子，而展示端又按本地日聚合，
两边长期对不上账。

时长取各章活动段之和（有效阅读时间，不含会话内空档，与本地计时语义一致）；
条目级与聚合结果 `<= 0` 一律丢弃 —— Kavita 会把「打开没读」的会话也写一条 0 时长记录。

身份粒度由调用方给（`volumes`：本地目录章数）：1 章的单卷系列记 series 行，多卷系列记
`seriesId:chapterId` 卷行。一条会话可以跨章（多卷）——时长 / 页数按章拆到各卷，
否则会把《2001》的时长记到《2010》头上。

账户日桶 `__kv:day:<当天零点>` 的页数按天**先求和再钳制**（`max(0, ·)`）：服务端 pagesRead
实测有负数（退页），逐条钳制会让 +1 / -1 相抵的当天凭空多出 1 页。

全量重拉：日桶 / 总量行按「前缀 + 覆盖到拉取时刻的时间窗」替换；单书行按「上次 ∪ 本次身份」
精确替换，顺带清掉身份漂移（单卷 ↔ 多卷、系列重建）遗留的孤儿行。

纯函数：无 IO、无全局状态；目录与「上次身份」由源钩子经 ctx 注入。

@module moonsource_kavita.stats
--]]

local logger = require("utils.log")

local Stats = {}

local DAY_PREFIX = "__kv:day:"
local TOTAL_ID = "__kv:total"

--- features/clock/init.lua 的 Clock.TIMEZONES 的 19 项 POSIX 串 → Kavita 的 TimeZoneId。
--- 只查表：不读 /etc/localtime（KOReader 设备上不保证存在，读到的也未必是用户选的时区），
--- 不按偏移猜地区。映射不上就让调用方按 UTC 请求：宁可与设备差一天，不要静默用错时区。
local IANA_BY_POSIX = {
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

--- 设备时钟的 POSIX 串 → IANA。未知 / 空串（跟随系统）回退 UTC 并记日志。
---@param posix string|nil features.clock 的 timezone 配置值
---@return string
function Stats.ianaTimezone(posix)
    local iana = type(posix) == "string" and IANA_BY_POSIX[posix] or nil
    if iana then return iana end
    logger.warn("kavita stats timezone unmapped, fallback to UTC", posix)
    return "UTC"
end

--- 合成 reading_stats 行；云端没有页坐标，page / total_pages 恒为 0。
---@param source_id string
---@param stable_id string
---@param record_type string
---@param start_time number
---@param duration number
---@param last_time number
---@return BookStatsRow
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

--- 服务端 localDate（"2026-10-15T00:00:00"）→ 当天设备本地零点；解不出返回 nil。
--- 只取日期部分：时刻是被请求时区下的零点，换算成设备本地同一日期即可。
---@param local_date any
---@return number|nil
local function localMidnight(local_date)
    local y, m, d = tostring(local_date):match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })
end

--- 本地目录章数：1 = 单卷（读在 series 行），>1 = 多卷（读在卷行）；拿不到返回 nil。
--- 数字 / 字符串键都收：状态文件里的 seriesId 可能两种写法。
---@param volumes table
---@param series_id string
---@return number|nil
local function volumeCount(volumes, series_id)
    local count = volumes[series_id]
    if count == nil then count = volumes[tonumber(series_id) or series_id] end
    count = tonumber(count)
    if not count or count < 1 then return nil end
    return count
end

---@class KavitaStatsContext
---@field source_id string 本源 id（写进每行）
---@field fetched_at number|nil 拉取时刻（缺省 now）；写进行 / 桶的 last_time
---@field volumes table<number|string, number>|nil seriesId → 本地目录章数（1 = 单卷）
---@field seen string[]|nil 上次拉取的身份列表（用于清身份漂移遗留的孤儿行）

--- reading-history 条目 → reading_stats 行 + 替换指令 + 本次身份。
---@param entries table[]|nil reading-history 条目（wire 已解码），通常为分页合并后的全量
---@param ctx KavitaStatsContext
---@return { rows: BookStatsRow[], replace: BookStatsPullReplace, identities: string[] }
function Stats.fromHistory(entries, ctx)
    ctx = ctx or {}
    local source_id = ctx.source_id
    local fetched_at = tonumber(ctx.fetched_at) or os.time()
    local volumes = ctx.volumes or {}

    local rows = {}
    local book_days = {} ---@type table<string, table<number, number>> 身份 → 日 → 秒
    local book_totals = {} ---@type table<string, number>
    local day_durations = {} ---@type table<number, number>
    local day_pages = {} ---@type table<number, number>
    local identities, known, warned_series = {}, {}, {}

    --- 记下本次出现的身份。零时长条目也记：它上次可能有行，靠 replace.books 清掉。
    local function noteIdentity(identity)
        if identity and not known[identity] then
            known[identity] = true
            identities[#identities + 1] = identity
        end
    end

    for _idx, entry in ipairs(type(entries) == "table" and entries or {}) do
        local series_id = entry.seriesId ~= nil and tostring(entry.seriesId) or nil
        local count = series_id and volumeCount(volumes, series_id) or nil
        if not count then
            -- 判不出单卷 / 多卷的系列整体跳过：身份是错的比缺行更糟（源钩子侧也会记）。
            if series_id and not warned_series[series_id] then
                warned_series[series_id] = true
                logger.warn("kavita stats skip series without volume info", series_id)
            end
        else
            local day = localMidnight(entry.localDate)
            if not day then
                logger.warn("kavita stats entry without usable localDate", series_id)
            else
                local chapters = type(entry.chapters) == "table" and entry.chapters or {}
                local entry_duration = 0
                for _ci, chapter in ipairs(chapters) do
                    entry_duration = entry_duration + (tonumber(chapter.durationSeconds) or 0)
                end
                -- 单卷：没有章行也读在 series 上；多卷：没有 chapterId 就拆不出来，跳过该章。
                if count == 1 then noteIdentity(series_id) end
                local contributes = entry_duration > 0
                for _ci, chapter in ipairs(chapters) do
                    local identity = series_id
                    if count > 1 then
                        identity = chapter.chapterId ~= nil
                            and (series_id .. ":" .. tostring(chapter.chapterId)) or nil
                        if not identity then
                            logger.warn("kavita stats chapter without chapterId", series_id)
                        end
                    end
                    noteIdentity(identity)
                    if contributes and identity then
                        local duration = tonumber(chapter.durationSeconds) or 0
                        if duration > 0 then
                            local days = book_days[identity]
                            if not days then
                                days = {}
                                book_days[identity] = days
                            end
                            days[day] = (days[day] or 0) + duration
                            book_totals[identity] = (book_totals[identity] or 0) + duration
                            day_durations[day] = (day_durations[day] or 0) + duration
                        end
                        day_pages[day] = (day_pages[day] or 0) + (tonumber(chapter.pagesRead) or 0)
                    end
                end
            end
        end
    end

    for identity, days in pairs(book_days) do
        for day, duration in pairs(days) do
            if duration > 0 then
                rows[#rows + 1] = statsRow(source_id, identity, "book_day", day, duration, fetched_at)
            end
        end
    end
    for identity, duration in pairs(book_totals) do
        if duration > 0 then
            rows[#rows + 1] = statsRow(source_id, identity, "book_total", fetched_at, duration, fetched_at)
        end
    end
    local grand_total = 0
    for day, duration in pairs(day_durations) do
        grand_total = grand_total + duration
        if duration > 0 then
            local row = statsRow(source_id, DAY_PREFIX .. tostring(day), "day", day, duration, fetched_at)
            row.event_count = math.max(0, day_pages[day] or 0)
            rows[#rows + 1] = row
        end
    end
    if grand_total > 0 then
        rows[#rows + 1] = statsRow(source_id, TOTAL_ID, "total", 0, grand_total, fetched_at)
    end

    -- 稳定输出：持久化顺序与对账都别受 pairs 遍历顺序影响。
    table.sort(rows, function(a, b)
        if a.record_type ~= b.record_type then return a.record_type < b.record_type end
        if a.start_time ~= b.start_time then return a.start_time < b.start_time end
        return a.stable_id < b.stable_id
    end)
    table.sort(identities)

    local books, book_known = {}, {}
    local function addBook(stable_id)
        if type(stable_id) == "string" and stable_id ~= "" and not book_known[stable_id] then
            book_known[stable_id] = true
            books[#books + 1] = stable_id
        end
    end
    for _idx, stable_id in ipairs(type(ctx.seen) == "table" and ctx.seen or {}) do addBook(stable_id) end
    for _idx, identity in ipairs(identities) do addBook(identity) end
    table.sort(books)

    return {
        rows = rows,
        replace = {
            mode = "ranges",
            ranges = {
                -- 全量重拉：窗口一直连到拉取时刻，清掉本次回包里已消失的日桶。
                -- 日桶 start_time 是「当天零点」，正常时区下不会晚于拉取时刻。
                { stable_prefix = DAY_PREFIX, from_ts = 0, to_ts = fetched_at },
                { stable_prefix = TOTAL_ID, from_ts = 0, to_ts = 0 },
            },
            -- 上次 ∪ 本次：身份漂移后旧身份不再出现在回包里，只能按它精确清。
            books = books,
        },
        -- 交回给源持久化：下次拉取当「上次身份」用。
        identities = identities,
    }
end

Stats.DAY_PREFIX = DAY_PREFIX
Stats.TOTAL_ID = TOTAL_ID

return Stats
