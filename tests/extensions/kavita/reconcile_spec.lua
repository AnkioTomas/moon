--[[--
Kavita 统计对账：真实响应 fixture 走「拉取钩子 → replaceSynced 入库 → 展示查询」全链，
逐项对 spec 的验收基线。HTTP 与目录缓存打桩，其余全真：源（分页 / 身份判定 / 物化）、
统计纯核心、真实 sqlite 的 reading_stats 与 books 库。

对账基线（research-kavita-stats-pull.md）：
  §2 全量逐日（29 天 / Σ=60,238s）、§3 样本 7453 逐日（13,921 + 316）、§4 系列累计。
数字都来自实测响应（fixture 数值逐条未改），不是照实现倒推的。

@module tests.extensions.kavita.reconcile_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Json = require("support.json_stub")
local Stubs = require("support.stubs")

-- 日 / 时归属按进程时区（POSIX TZ）计算：钉死 CST-8，与 fixture 拉取时用的 Asia/Shanghai 对齐，
-- 断言就不会随宿主机时区漂移。
local ffi = require("ffi")
ffi.cdef[[ int setenv(const char*, const char*, int); void tzset(void); ]]
ffi.C.setenv("TZ", "CST-8", 1)
ffi.C.tzset()

local sqlite_ok = pcall(require, "lua-ljsqlite3/init")
if not sqlite_ok then
    Assert.skip("当前离线环境没有 ljsqlite3 Lua 模块")
end

-- 沙箱库：books 与 reading_stats 同库，物化行和统计行一起对账。
local db_path = Config.dir() .. "/kavita_reconcile_spec.sqlite3"
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
package.loaded["utils.paths"] = nil
package.preload["utils.paths"] = function()
    return {
        dbPath = function() return db_path end,
        ensureSettings = function() end,
        sanitizeSourceId = function(id) return id end,
    }
end

-- 响应体 / 分页头走真实编解码（source_spec 的往返桩同形）；books 的 meta 列也用它。
package.loaded["json"] = nil
package.preload["json"] = function()
    return { encode = Json.encode, decode = Json.decode }
end

-- 设备时钟（POSIX → IANA 映射）与扩展配置；stats_db 也会问 merge_local_stats（本用例默认关）。
local clock = { timezone = "CST-8" }
local cfg = { base_url = "http://kav/", api_key = " k ", libraries = { ["8"] = true, ["10"] = true } }
package.loaded["utils.settings"] = nil
package.preload["utils.settings"] = function()
    local common = { active_source = "local" }
    return {
        get = function(key) return key == "features.clock" and clock or common end,
        getSource = function() return cfg end,
    }
end

-- 插件模块走 preload：不把插件根塞进 package.path（main.lua 会顶掉月读的 main）。
local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"
for _idx, name in ipairs({ "client", "position", "annotation", "cache", "volume_list", "source", "stats" }) do
    package.preload["moonsource_kavita." .. name] = function()
        return dofile(PLUGIN .. "/moonsource_kavita/" .. name .. ".lua")
    end
end

-- HTTP：只服务阅读历史；目录全部命中缓存，物化与身份判定不发请求。
-- 分页头与 body 同一套编解码（同真服务端：PageSize=200、总页数在响应头里）。
local pagination_calls = {}
local sample = dofile(Config.root() .. "/tests/extensions/kavita/fixtures/history_all.lua")
local history = sample
local function history_pages()
    local pages = { {}, {} }
    for _idx, entry in ipairs(history) do
        local page = #pages[1] < 200 and 1 or 2
        pages[page][#pages[page] + 1] = entry
    end
    return pages
end
local function query(opts, key) return opts.url:match("[?&]" .. key .. "=([^&]*)") end
package.loaded["http.request"] = {
    ok = function(code)
        code = tonumber(code)
        return code ~= nil and code >= 200 and code < 300
    end,
    header = function(res, name)
        for key, value in pairs(res and res.headers or {}) do
            if type(key) == "string" and key:lower() == name:lower() then return value end
        end
    end,
    request = function(opts, cb)
        local page = tonumber(query(opts, "PageNumber")) or 1
        pagination_calls[#pagination_calls + 1] = opts.url
        -- 只认阅读历史：目录 / 其它接口意外被请求时返回 404（身份判定该走目录缓存，
        -- 真机也是：判定结果记在状态文件里，不该为身份反复请求目录）。
        local history_call = opts.url:find("/api/Stats/reading%-history", 1) ~= nil
        require("ui/uimanager"):nextTick(function()
            if not history_call then
                cb({ code = 404, body = "" })
                return
            end
            cb({
                code = 200,
                body = Json.encode(history_pages()[page]),
                headers = { Pagination = Json.encode({
                    currentPage = page,
                    itemsPerPage = 200,
                    totalItems = #history,
                    totalPages = math.max(1, math.ceil(#history / 200)),
                }) },
            })
        end)
        return { cancel = function() end }
    end,
}

-- 目录缓存（source.toc）替身：身份判定只关心「1 章还是多章」，物化只用条目 title。
-- 7453 用实测目录（4 卷含卷名，research §5 / series-detail）；已知实测章数的系列对齐 §5；
-- 其余按云端读到的章构造 —— 判定结果只影响单书身份粒度，不影响账户日桶。
local CLOUD_TITLES = {
    ["7453"] = {
        { chapterId = 11271, title = "2001：太空漫游" },
        { chapterId = 11273, title = "2010：太空漫游" },
        { chapterId = 11270, title = "2061：太空漫游" },
        { chapterId = 11272, title = "3001：太空漫游" },
    },
}
local TOC_COUNTS = { ["7453"] = 4, ["10634"] = 27, ["7460"] = 2, ["10720"] = 5, ["8661"] = 1, ["7606"] = 1 }
local tocs = {}
for _idx, entry in ipairs(sample) do
    local series_id = tostring(entry.seriesId)
    local toc = tocs[series_id]
    if not toc then toc = {}; tocs[series_id] = toc end
    -- 全量取并：同一系列各条会话可能各读不同章，真目录里这些章都在。
    for _i, chapter in ipairs(entry.chapters) do
        if chapter.chapterId then
            local known = false
            for _k, item in ipairs(toc) do
                if item.chapterId == chapter.chapterId then known = true end
            end
            if not known then toc[#toc + 1] = { chapterId = chapter.chapterId } end
        end
    end
end
for series_id, entries in pairs(CLOUD_TITLES) do tocs[series_id] = entries end
for series_id, count in pairs(TOC_COUNTS) do
    -- 补齐到实测章数：补齐条目不带 chapterId，只有 #toc 参与单卷 / 多卷判定。
    while #tocs[series_id] < count do tocs[series_id][#tocs[series_id] + 1] = {} end
end
package.loaded["source.toc"] = {
    read = function(_sid, series_id) return tocs[tostring(series_id)] end,
    put = function(_sid, series_id, list) tocs[tostring(series_id)] = list; return true end,
}

-- 统计状态文件（上次身份 + 章数判定）是上一轮的残留：连 .old 备份一起清，
-- 清了才是「首次拉取」（LuaSettings 读不到主文件会回落 .old）。
local STATS_STATE = require("datastorage"):getSettingsDir() .. "/moonsource_kavita_stats.lua"
local function clearStatsState()
    for _idx, suffix in ipairs({ "", ".old" }) do os.remove(STATS_STATE .. suffix) end
end
clearStatsState()

local Base = require("utils.db")
local StatsDB = require("book.stats_db")
local BookDB = require("book.books_db")
local ProgressDB = require("book.progress_db")
local Kavita = require("moonsource_kavita.source")
Assert.not_nil(Base.open())

-- 书架容器行（书架同步的产物）：统计侧只当物化标题 / 元数据来源。作者只给断言用到的那本。
local function container(id, title, authors)
    Assert.is_true(BookDB.upsertRemote({ source_id = "ext.kavita", stable_id = id, title = title,
        authors = authors, deleted = 0 }, false, true))
end
container("7453", "太空漫游", "阿瑟·克拉克")
container("8661", "人类简史")
container("7460", "三国演义")
container("10634", "大剑")

-- 本机逐页记录：10-14 已上报（云端会话已含，不能再算一遍）；10-17 拉取后才读（未上报）。
local L1_T = os.time({ year = 2026, month = 10, day = 14, hour = 21 })
Assert.is_true(StatsDB.add({
    source_id = "ext.kavita", stable_id = "7453:11273", record_type = "page",
    page = 30, start_time = L1_T, duration = 900, total_pages = 150,
}, StatsDB.SYNCED))

-- 固定拉取时刻（2026-10-16 20:00 本地，晚于全量最后一天）：只看 nil 参数的 os.time。
local FETCHED = 1792152000
local real_time = os.time
os.time = function(t)
    if t == nil then return FETCHED end
    return real_time(t)
end
local source = Kavita.new()

--- 一次完整的统计同步：拉取 → 入库 → commit（状态文件只在入库成功后前进）。
---@return BookStatsPullResult
local function pull()
    local result, err
    source:pullStatsAsync(function(res, pull_err) result, err = res, pull_err end)
    Stubs.flush()
    Assert.not_nil(result, err)
    Assert.not_nil(StatsDB.replaceSynced("ext.kavita", result.replace, result.rows), "入库必须成功")
    result.commit()
    return result
end

local pulled = pull()

--- 逐日聚合（dailyBySource）：ymd → { seconds, pages }。
local function calendar()
    local rows = {}
    for _idx, row in ipairs(StatsDB.dailyBySource("ext.kavita")) do rows[row.ymd] = row end
    return rows
end

-- ① 单书累计：与云端 Σ 一致（§3 的 7453 两卷 / §4 的系列累计）。
-- 10-14 的本地 900s 已含在云端快照里（sync_status=1 且早于拉取时刻）：不加第二遍。
Assert.eq(StatsDB.summaryByBook("ext.kavita", "7453:11273").total_seconds, 13921, "样本卷累计 = 云端 Σ")
Assert.eq(StatsDB.summaryByBook("ext.kavita", "7453:11271").total_seconds, 316, "同系列另一卷（只在其它设备读过）")
Assert.eq(StatsDB.summaryByBook("ext.kavita", "7453").total_seconds, 0, "多卷系列不读在容器行上")
Assert.eq(StatsDB.summaryByBook("ext.kavita", "8661").total_seconds, 3555, "单卷系列读在 series 行（§4）")
Assert.eq(StatsDB.summaryByBook("ext.kavita", "7460:11285").total_seconds, 9517, "多章目录 → 逐卷身份（§4）")
-- 页数：云端会话的 pagesRead + 未被会话覆盖的本地页（18 号票）。10-14 的本地 1 页已上报、
-- 当天有会话覆盖，不再加；22 是该卷各云端会话 pagesRead 之和。
Assert.eq(StatsDB.summaryByBook("ext.kavita", "7453:11273").pages, 22, "单书页数 = 云端会话 pagesRead 之和")

-- ② 日历逐日与 §2 一致；合计 = __kv:total。
-- 页数口径与 §2 的 hist_p 在 9-19 / 9-24 / 9-29 差 1 / 1 / 2 页：那 4 页来自零时长条目，
-- 设计上整条丢弃（§4 已记「零时长条目 100 条，其中带页数 4 条合计 4 页」）。
local CLOUD_DAYS = {
    { "2026-09-18", 920, 5 }, { "2026-09-19", 2824, 10 }, { "2026-09-20", 2813, 25 },
    { "2026-09-21", 1183, 18 }, { "2026-09-22", 1682, 25 }, { "2026-09-23", 406, 18 },
    { "2026-09-24", 1179, 114 }, { "2026-09-25", 10, 3 }, { "2026-09-26", 1378, 71 },
    { "2026-09-27", 755, 0 }, { "2026-09-28", 104, 0 }, { "2026-09-29", 7942, 312 },
    { "2026-09-30", 6640, 22 }, { "2026-10-01", 643, 23 }, { "2026-10-03", 1104, 25 },
    { "2026-10-04", 638, 1 }, { "2026-10-05", 195, 0 }, { "2026-10-06", 809, 0 },
    { "2026-10-07", 503, 0 }, { "2026-10-08", 3663, 10 }, { "2026-10-09", 1092, 93 },
    { "2026-10-10", 363, 10 }, { "2026-10-11", 649, 26 }, { "2026-10-12", 1803, 103 },
    { "2026-10-13", 4514, 244 }, { "2026-10-14", 11665, 120 }, { "2026-10-15", 4541, 118 },
    { "2026-10-16", 220, 6 },
}
local days = calendar()
local day_count = 0
for _ymd in pairs(days) do day_count = day_count + 1 end
Assert.eq(day_count, #CLOUD_DAYS, "只有有有效时长的日子落桶（10-02 三条会话全零时长）")
Assert.is_nil(days["2026-10-02"], "零时长日不留桶")
-- 页数：本地逐页记录按条累加（10-14 的本机 900s 是 1 页）；云端日桶的 event_count 到了
-- StatsDB.add 会被兜底成 ≥1（page 行本来就该 ≥1），于是云端当天 0 页的 5 天各显示 1 页。
-- 这是 stats_db.add 的既有实现，本票不改核心，只按真实入库口径对账（显示差记在 acceptance）。
local ZERO_PAGE_DAYS = 0
for _idx, expected in ipairs(CLOUD_DAYS) do
    local row = days[expected[1]]
    Assert.not_nil(row, "缺日桶 " .. expected[1])
    Assert.eq(row.seconds, expected[2], "日时长 " .. expected[1])
    local stored_pages = math.max(1, expected[3]) + (expected[1] == "2026-10-14" and 1 or 0)
    if expected[3] == 0 then ZERO_PAGE_DAYS = ZERO_PAGE_DAYS + 1 end
    Assert.eq(row.pages, stored_pages, "日页数增量 " .. expected[1])
end
Assert.eq(ZERO_PAGE_DAYS, 5, "云端 0 页日就 5 天（09-27 / 09-28 / 10-05~10-07）")
local calendar_sum, calendar_pages = 0, 0
for _ymd, row in pairs(days) do
    calendar_sum = calendar_sum + row.seconds
    calendar_pages = calendar_pages + row.pages
end
Assert.eq(StatsDB.summaryBySource("ext.kavita").total_pages, calendar_pages, "总页数 = 日历逐日之和")
Assert.eq(calendar_sum, 60238, "各日之和 = 云端全量 Σ（§2）")
local total_row
for _idx, row in ipairs(pulled.rows) do
    if row.record_type == "total" then total_row = row end
end
Assert.eq(total_row.duration, calendar_sum, "总时长 = __kv:total")
Assert.eq(StatsDB.summaryBySource("ext.kavita").total_seconds, calendar_sum, "总览合计 = 日历合计")

-- 分页：分页头说 2 页就拉 2 页，参数形态同真服务端。
Assert.len(pagination_calls, 2)
Assert.matches(pagination_calls[1], "Libraries=8")
Assert.matches(pagination_calls[1], "Libraries=10")
Assert.matches(pagination_calls[1], "PageNumber=1&PageSize=200")
Assert.matches(pagination_calls[1], "TimeZoneId=Asia%%2FShanghai")
Assert.matches(pagination_calls[2], "PageNumber=2&")

-- ③ 当日书单：云端读过、本机从没打开过的书也在；单书逐日与云端一致。
local by_day_book = {}
for _idx, row in ipairs(StatsDB.dailyBooksBySource("ext.kavita")) do
    by_day_book[row.ymd] = by_day_book[row.ymd] or {}
    by_day_book[row.ymd][row.stable_id] = row
end
Assert.eq(by_day_book["2026-09-29"]["7453:11271"].seconds, 316, "只在其它设备读过的卷进当日书单")
Assert.eq(by_day_book["2026-09-29"]["7453:11271"].max_total_pages, 0, "只有云端时长的那天没有页坐标")
Assert.eq(by_day_book["2026-09-30"]["8661"].seconds, 2885, "单卷系列按 series 身份进当日书单")
Assert.eq(by_day_book["2026-10-15"]["10634:17868"].seconds, 531, "多卷按章拆到各卷（210 + 321）")

-- 12 号票物化的隐藏身份行：书单里的云端书能显示书名（不是裸 ID），且不上架 / 不标脏 / 不写进度。
local cloud_only = BookDB.get("ext.kavita", "7453:11271")
Assert.eq(cloud_only.title, "太空漫游 · 2001：太空漫游", "标题 = 系列 · 卷名")
Assert.eq(cloud_only.authors, "阿瑟·克拉克", "作者继承容器行")
Assert.eq(cloud_only.deleted, 1, "隐藏身份行：不进书架")
Assert.eq(cloud_only.sync_status, 1, "隐藏身份行：不标脏、不推云端")
Assert.is_nil(ProgressDB.get("ext.kavita", "7453:11271"), "统计拉取不写进度：不会因此冒进「最近阅读」")
local shelf_ids = BookDB.libraryStableIdsBySource("ext.kavita")
local materialized_on_shelf = false
for _idx, id in ipairs(shelf_ids) do
    if id == "7453:11271" or id == "7453:11273" then materialized_on_shelf = true end
end
Assert.is_false(materialized_on_shelf, "物化行不是书架成员")
-- 容器行缺失的系列：物化跳过（12 号票语义），统计行照写。
Assert.is_nil(BookDB.get("ext.kavita", "7910:11896"), "没有容器行就不物化")
Assert.eq(by_day_book["2026-09-29"]["7910:11896"] ~= nil, true, "不物化不影响统计行")

-- 单书逐日（详情页「最近几天」）与云端 §3 一致；10-14 = 云端 6734（本地 900 已含，不再加）。
local function book_days(stable_id)
    local rows, count = {}, 0
    for _idx, row in ipairs(StatsDB.dailyByBook("ext.kavita", stable_id, 40)) do
        rows[row.ymd] = row.seconds
        count = count + 1
    end
    return rows, count
end
local sample_days = {
    ["2026-10-05"] = 195, ["2026-10-07"] = 503, ["2026-10-08"] = 2036, ["2026-10-11"] = 512,
    ["2026-10-13"] = 979, ["2026-10-14"] = 6734, ["2026-10-15"] = 2962,
}
local sample_rows, sample_day_count = book_days("7453:11273")
Assert.eq(sample_rows["2026-10-14"], 6734, "云+本地同一天不双计")
Assert.eq(sample_day_count, 7, "只列有数据的日子（零时长日不出现）")
for ymd, seconds in pairs(sample_days) do Assert.eq(sample_rows[ymd], seconds, "单书逐日 " .. ymd) end
Assert.eq(book_days("7453:11271")["2026-09-29"], 316)

-- ④ 时段：云端时段桶 + 本机逐页记录，合并口径与按天一致。
local hourly = StatsDB.hourlyBySource("ext.kavita")
local hourly_days = 0
for _ymd in pairs(hourly) do hourly_days = hourly_days + 1 end
Assert.eq(hourly["2026-10-14"][22], 1043, "10-14 21 点：云端该格 1043s（本机同格已上报，不叠加）")
Assert.eq(hourly_days, 28, "有云端时长的每天都有时段分布")
Assert.eq(hourly["2026-09-18"][18], 738, "纯云端的日子也有时段（21 点 174 + 17 点 738 …）")
-- 日页面「标题时长 = 时段图逐格之和」：逐日必须对得上
for _idx, row in ipairs(StatsDB.dailyBySource("ext.kavita")) do
    local sum = 0
    for h = 1, 24 do sum = sum + (hourly[row.ymd] and hourly[row.ymd][h] or 0) end
    Assert.eq(sum, row.seconds, "时段逐日之和 = 日历 " .. row.ymd)
end

-- ⑤ 拉取后本地新读：云端快照 + 增量，两边都不双计。
local L2_T = FETCHED + 5 * 3600
Assert.is_true(StatsDB.add({
    source_id = "ext.kavita", stable_id = "7453:11273", record_type = "page",
    page = 31, start_time = L2_T, duration = 90, total_pages = 150,
}, StatsDB.PENDING))
Assert.eq(StatsDB.summaryByBook("ext.kavita", "7453:11273").total_seconds, 13921 + 90, "快照 + 拉取后新读")
Assert.eq(book_days("7453:11273")["2026-10-17"], 90, "增量单落到它自己的日子")
Assert.eq(calendar()["2026-10-17"].seconds, 90, "日历同样叠加增量")
Assert.eq(StatsDB.summaryBySource("ext.kavita").total_seconds, 60238 + 90, "总览 = __kv:total + 拉取后新读")
Assert.eq(StatsDB.hourlyBySource("ext.kavita")["2026-10-17"][2], 90, "增量进时段（1 点 = 第 2 格）")

-- 再拉一次（本次只回样本 7453）：整本替换不累加，云端消失的日桶清掉，本地逐页记录不动。
history = dofile(Config.root() .. "/tests/extensions/kavita/fixtures/history_7453.lua")
pulled = pull()
Assert.not_nil(pulled.rows[1])
Assert.eq(StatsDB.summaryByBook("ext.kavita", "7453:11273").total_seconds, 13921 + 90, "重拉不累加，增量仍在")
Assert.eq(StatsDB.summaryByBook("ext.kavita", "8661").total_seconds, 0, "云端消失的书回落本地（没有本地记录 = 0）")
local again = calendar()
Assert.is_nil(again["2026-09-18"], "上一轮的云端日桶被全量重拉清掉")
Assert.eq(again["2026-10-14"].seconds, 6734, "样本日重写为本次回包值")
Assert.eq(again["2026-10-17"].seconds, 90, "本地逐页记录不受替换影响")
Assert.eq(StatsDB.hourlyBySource("ext.kavita")["2026-10-14"][22], 716, "时段格重写为本次回包值（本机同格已上报，不叠加）")
Assert.is_nil(StatsDB.hourlyBySource("ext.kavita")["2026-09-18"], "回包里消失的时段格清掉")

-- 12 号票物化标题的第二轮回归：二次拉取时章数已判定（不再读目录），卷名必须取自状态文件里的
-- 持久化卷名 —— 不能退容器名，更不能把上一轮物化出的好标题改写成「太空漫游 · 太空漫游」。
Assert.eq(BookDB.get("ext.kavita", "7453:11271").title, "太空漫游 · 2001：太空漫游", "二次拉取后标题不回退")
Assert.eq(BookDB.get("ext.kavita", "7453:11273").title, "太空漫游 · 2010：太空漫游")

-- 升级路径：老状态文件只有章数、没有卷名（本机第一轮物化时还没有持久化）。此时兜底标题
-- 只能用于新行，不得覆盖既有行的真实标题。
local stats_state = require("luasettings"):open(STATS_STATE)
stats_state:saveSetting("titles", {})
stats_state:flush()
pulled = pull()
Assert.eq(BookDB.get("ext.kavita", "7453:11271").title, "太空漫游 · 2001：太空漫游",
    "没有持久化卷名时，兜底标题不覆盖既有标题")

os.time = real_time
Base.close()
for _idx, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(db_path .. suffix) end
clearStatsState()
