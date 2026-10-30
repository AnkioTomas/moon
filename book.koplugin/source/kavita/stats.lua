--[[--
Kavita 阅读统计纯核心：reading-history 条目 + 身份 / 时区上下文 → reading_stats 行与替换指令。

条目是「会话 × 系列」切片。日 / 时归属按服务端给的 UTC 时刻（`startTimeUtc`）在**设备本地时区**
自行分桶：展示端（SQLite `localtime`、`os.date`）用的是同一个进程时区，两边同一真源才对得上账。
服务端 `localDate` 是它按请求的 `TimeZoneId` 预先算的日期，映射不上时回退 UTC 会把整段挪一天，
所以它只当拿不到 `startTimeUtc` 时的兜底。

时长取各章活动段之和（有效阅读时间，不含会话内空档，与本地计时语义一致）；
条目级与聚合结果 `<= 0` 一律丢弃 —— Kavita 会把「打开没读」的会话也写一条 0 时长记录。

身份粒度由调用方给（`volumes`：本地目录章数）：1 章的单卷系列记 series 行，多卷系列记
`seriesId:chapterId` 卷行。一条会话可以跨章（多卷）——时长 / 页数按章拆到各卷，
否则会把《2001》的时长记到《2010》头上。

账户日桶 `__kv:day:<当天零点>` 的页数按天**先求和再钳制**（`max(0, ·)`）：服务端 pagesRead
实测有负数（退页），逐条钳制会让 +1 / -1 相抵的当天凭空多出 1 页。漫画不用 pagesRead 求和，
而是按最远进度算新推进的页数（见下），贡献本身已 >= 0。

账户时段桶 `__kv:hour:<整点>`：每条活动行的时长记在它起始时刻所在的那个本地整点（跨整点的活动行
整体算起始小时，与「跨零点的会话整体算起始日」同一口径），供「阅读时段」图用；云端只有这一层
粒度，再细就要按跨度分摊，而活动行的跨度含空档，分摊反而把空档算到隔壁小时。

阅读会话行（`cloud_session`）：每个「会话 × 章」切片的起始时刻与时长单独落一行，
供书详情 / 统计页的「阅读记录」列出真的读了几点几分；时长不计入日 / 时段 / 总量行
（那些桶已经包含它），只在 `sessionRows` 里读。页数（`event_count`）不另写记录类型：
核心从这一行累加单书页数。页数口径分两种：

- 漫画（Image / Archive）：`event_count` = **本次新推进的页数**，不是 `pagesRead`。
  `pagesRead` 是「这次翻了多少页」，重读会重复计入（实测 194 页的卷求和 284）；
  按最远进度算，`SUM(event_count)` 才等于读到的最远页码（≤ 总页数），与 Kavita 的百分比一致。
  所以漫画还要补 `page = endPage` / `total_pages = 卷级总页数`。
- epub / PDF：`pagesRead` 是唯一页数来源，`event_count` 照旧；页坐标仍为 0。

全量重拉：日桶 / 时段桶 / 总量行按「前缀 + 覆盖到最后观测桶的时间窗」替换；单书行按「上次 ∪ 本次
身份」精确替换，顺带清掉身份漂移（单卷 ↔ 多卷、系列重建）遗留的孤儿行。

纯函数（无文件 / 网络 IO、无全局状态，只经 `logger` 写日志）：目录、卷名与「上次身份」由源钩子经 ctx 注入。

@module source.kavita.stats
--]]

local logger = require("utils.log")

local Stats = {}

local DAY_PREFIX = "__kv:day:"
local HOUR_PREFIX = "__kv:hour:"
local TOTAL_ID = "__kv:total"
--- 单条阅读会话（会话 × 章切片）——只给「阅读记录」列表用，不参与任何时长汇总。
local SESSION_RECORD = "cloud_session"

--- features/clock/init.lua 的 Clock.TIMEZONES 的 19 项 POSIX 串 → Kavita 的 TimeZoneId。
--- 只查表：不读 /etc/localtime（KOReader 设备上不保证存在，读到的也未必是用户选的时区），
--- 不按偏移猜地区。映射不上就按 UTC 请求 —— 只影响 `localDate` 这个兜底（正常条目都带
--- `startTimeUtc`，分日 / 分时按设备本地时区自行换算，见 utcEpoch / dayStart）。
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
---@param posix string|nil 进程 TZ 环境变量（时钟功能按设置写入）
---@return string
function Stats.ianaTimezone(posix)
    local iana = type(posix) == "string" and IANA_BY_POSIX[posix] or nil
    if iana then return iana end
    logger.warn("kavita stats timezone unmapped, fallback to UTC", posix)
    return "UTC"
end

--- 合成 reading_stats 行；云端默认没有页坐标，page / total_pages 恒为 0。
--- 漫画（Image / Archive）的会话行由调用方在拿到 endPage / totalPages 后补上。
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

--- 服务端 UTC 时间戳（"2026-10-15T23:51:47.4527045"）→ 设备本地 epoch；解不出返回 nil。
--- os.time 按进程 TZ（POSIX 串，自带夏令时规则）解释墙钟，所以先把 UTC 墙钟当本地算出 E'，
--- 再补回一个用 E' 处的本地偏移量的差。偏移的表必须重建：os.date 给的表带 `isdst`，直接回喂
--- os.time 会把夏令时钉成标准时、整整差一小时（跨夏令时切换的时区实测过）。
---@param text any
---@return number|nil
local function utcEpoch(text)
    local y, mo, d, h, mi, s = tostring(text):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then return nil end
    local as_local = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
    if not as_local then return nil end
    local u = os.date("!*t", as_local)
    local back = os.time({ year = u.year, month = u.month, day = u.day, hour = u.hour, min = u.min, sec = u.sec })
    return as_local + os.difftime(as_local, back)
end

--- 设备本地时区的当日零点。`isdst` 取自本地分解，跨切换的零点不会被挪一小时。
---@param epoch number
---@return number
local function dayStart(epoch)
    local t = os.date("*t", epoch)
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, isdst = t.isdst })
end

--- 时段桶键：`day` 那天的、`epoch` 所在小时。跨零点的活动行仍记在条目那天（取小时、换日期），
--- 这样「日页面逐格之和 = 当日日桶」，不会出现某天的时段和比标题少一截。
---@param day number 当日零点
---@param epoch number 活动行起始时刻
---@return number
local function hourBucket(day, epoch)
    local d = os.date("*t", day)
    local a = os.date("*t", epoch)
    return os.time({ year = d.year, month = d.month, day = d.day, hour = a.hour, isdst = a.isdst })
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

--- 漫画章行：页数贡献要按身份排完序才能算（见 fromHistory 里「漫画最远进度」一段）。
---@class KavitaComicSlice
---@field identity string 卷身份（单卷 = seriesId，多卷 = seriesId:chapterId）
---@field day number 该活动行归属的本地零点（推进的页数记进这一天）
---@field epoch number|nil 会话行 start_time（也是排序键）
---@field order number 回包顺序，仅用于同一时刻的稳定排序
---@field duration number 秒；`> 0` 才发行
---@field page number 原始 endPage（会话行的进度坐标）
---@field end_page number 钳到总页数后的结束页（算推进页数用）
---@field total_pages number 卷级总页数

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
    local hour_durations = {} ---@type table<number, number> 整点 → 秒（账户时段桶）
    local last_day = 0 ---@type number 本次回包里最晚的观测日（零点）
    local last_hour = 0 ---@type number 本次回包里最晚的观测整点
    local comic_slices = {} ---@type KavitaComicSlice[] 漫画章行，算完进度贡献再落行
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
            -- 有 UTC 时刻就按设备本地分日 / 分时；没有才退服务端按请求时区算好的 localDate（无小时）。
            local anchor = utcEpoch(entry.startTimeUtc)
            local day
            if anchor then
                day = dayStart(anchor)
            else
                day = localMidnight(entry.localDate)
                if day then logger.warn("kavita stats entry without usable startTimeUtc", series_id) end
            end
            if not day then
                logger.warn("kavita stats entry without usable day", series_id)
            else
                if day > last_day then last_day = day end
                local chapters = type(entry.chapters) == "table" and entry.chapters or {}
                -- 漫画才有真实页坐标：Kavita 的 seriesFormat 0 = Image、1 = Archive 是图片页；
                -- epub（3）的 chapter.pages 是 spine / 阅读单元（6 万字的书 32 个），PDF（4）同理，
                -- 都不是渲染页，填进 page / total_pages 会让详情页的「读了多少页」变成假的。
                -- seriesFormat 在条目顶层，不在 chapter 上（实测响应见 history-7453-all.json）。
                local fmt = tonumber(entry.seriesFormat)
                local comic = fmt == 0 or fmt == 1
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
                    if identity then
                        local duration = tonumber(chapter.durationSeconds) or 0
                        -- 章活动行自己的起始时刻（时段桶 / 会话行 / 漫画排序共用）；拿不到就退回条目起始时刻。
                        local chapter_epoch = utcEpoch(chapter.startTimeUtc) or anchor
                        if contributes and duration > 0 then
                            local days = book_days[identity]
                            if not days then
                                days = {}
                                book_days[identity] = days
                            end
                            days[day] = (days[day] or 0) + duration
                            book_totals[identity] = (book_totals[identity] or 0) + duration
                            day_durations[day] = (day_durations[day] or 0) + duration
                            -- 时段桶：按活动行自己的起始小时；拿不到就退回条目起始时刻。
                            if chapter_epoch then
                                local bucket = hourBucket(day, chapter_epoch)
                                hour_durations[bucket] = (hour_durations[bucket] or 0) + duration
                                if bucket > last_hour then last_hour = bucket end
                            end
                        end
                        if comic then
                            -- 漫画的页数不能边遍历边累加：`pagesRead` 是「这次翻了多少页」，重读会重复计入。
                            -- 先收集，按身份（卷）× 起始时刻排序后再算「本次新推进的页数」。
                            local total_pages = math.max(0, tonumber(chapter.totalPages) or 0)
                            local page = math.max(0, tonumber(chapter.endPage) or 0)
                            comic_slices[#comic_slices + 1] = {
                                identity = identity,
                                day = day,
                                epoch = chapter_epoch,
                                order = #comic_slices + 1,
                                duration = duration,
                                page = page,
                                -- 只有拿到总页数才钳：缺总页数时别凭空假设一个上界。
                                end_page = total_pages > 0 and math.min(page, total_pages) or page,
                                total_pages = total_pages,
                            }
                        elseif contributes then
                            if duration > 0 and chapter_epoch then
                                -- 阅读会话行：详情「阅读记录」按真实起止时间列出这一段。
                                local session = statsRow(source_id, identity, SESSION_RECORD,
                                    chapter_epoch, duration, fetched_at)
                                session.event_count = math.max(0, tonumber(chapter.pagesRead) or 0)
                                rows[#rows + 1] = session
                            end
                            day_pages[day] = (day_pages[day] or 0) + (tonumber(chapter.pagesRead) or 0)
                        end
                    end
                end
            end
        end
    end

    -- 漫画：按身份（卷）分别按起始时刻升序走一遍，只留「比此前更远」的页数 —— 这样重读不再重复计入，
    -- 跳读也只按推进到哪算，`SUM(event_count)` = 读到的最远页码（天然 ≤ 总页数），与 Kavita 百分比一致。
    -- 回包可能是新→旧（服务端按时间倒序），所以必须排序，不能依赖遍历顺序。
    table.sort(comic_slices, function(a, b)
        if a.identity ~= b.identity then return a.identity < b.identity end
        local ae, be = a.epoch or 0, b.epoch or 0
        if ae ~= be then return ae < be end
        return a.order < b.order
    end)
    local reached = {} ---@type table<string, number> 身份（卷）→ 此前到达的最远页码
    for _idx, slice in ipairs(comic_slices) do
        local previous = reached[slice.identity] or 0
        local advance = slice.end_page - previous
        if advance < 0 then advance = 0 end
        if slice.end_page > previous then reached[slice.identity] = slice.end_page end
        -- 零时长章行不发行（会话行说的是「这一段读了多久」），但推进照样算进当天页数：
        -- 否则这次跳读会从当天页数里消失，而后续会话又因 reached 更高而少算。
        day_pages[slice.day] = (day_pages[slice.day] or 0) + advance
        -- 零时长章行也要发行：Kavita 的会话是「两次进度写入之间」，只写一次（开书 / 关书各一次）
        -- 就是 0 秒，但推进的页数是真的。丢掉它，详情页「已读页数 / 上次阅读」会整段消失
        -- （另一台设备刚读的那一卷尤其明显）。既没时长又没推进的（打开没翻）才跳过。
        if slice.epoch and (slice.duration > 0 or advance > 0) then
            local session = statsRow(source_id, slice.identity, SESSION_RECORD,
                slice.epoch, slice.duration, fetched_at)
            session.event_count = advance
            -- page = endPage（读到哪一页，核心 reading_stats.page 的语义）；total_pages 取卷级，
            -- 多卷系列汇总处取 MAX。pagesRead = 0 是合法值（打开没翻页），不是缺数据。
            session.page = slice.page
            session.total_pages = slice.total_pages
            rows[#rows + 1] = session
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
    for hour, duration in pairs(hour_durations) do
        if duration > 0 then
            rows[#rows + 1] = statsRow(source_id, HOUR_PREFIX .. tostring(hour), "hour", hour, duration, fetched_at)
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
                -- 全量重拉：窗口一直连到最后观测日 / 整点的桶止，清掉本次回包里已消失的桶。
                -- 上界不能只取拉取时刻：服务端「当天」可能晚于设备本地的拉取时刻（设备为负偏移），
                -- 桶零点会落在窗口外、清不掉（残留到下一轮）。
                { stable_prefix = DAY_PREFIX, from_ts = 0, to_ts = math.max(fetched_at, last_day + 86399) },
                { stable_prefix = HOUR_PREFIX, from_ts = 0, to_ts = math.max(fetched_at, last_hour + 3599) },
                { stable_prefix = TOTAL_ID, from_ts = 0, to_ts = 0 },
            },
            -- 上次 ∪ 本次：身份漂移后旧身份不再出现在回包里，只能按它精确清。
            books = books,
        },
        -- 交回给源持久化：下次拉取当「上次身份」用。
        identities = identities,
    }
end

return Stats
