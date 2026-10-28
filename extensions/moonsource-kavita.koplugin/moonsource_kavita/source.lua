--[[--
Kavita 书源（整本模式）。

身份：
  - 书架一行 = 一个 series，stable_id = seriesId，分类 = 库名。
  - 单卷 series 直接下载到 series 行；多卷 series 打开时选卷，每卷一行隐藏的书
    （stable_id = "seriesId:chapterId"，不上书架，只在最近阅读里出现），进度按卷同步。
目录缓存（source.toc，挂在 series 行）存每卷的 chapterId/volumeId/libraryId/format/pages，
是进度上报所需 id 的唯一来源；离线时目录过期也照用旧的。

进度：epub 按 spine（Kavita pageNum）+ bookScrollId，pdf/cbz 按页。
远端只有 spine 粒度（网页端没带锚点、或锚点在本机 epub 里解不出）且本地在同一 spine / 页时
交回本地位置：Kavita 的精度只到 spine，不能拿它把本地章内位置判成冲突、把人拽回节首。
远端能给得出页内锚点时必须用远端：网页端在同一条里往后读几页就是这种情况，
先返回本地会让 core 的 synced 基线永远判不出「云端动过」。
关书 / 切章 / 休眠各推一次，另在阅读期做「进度心跳」（间隔见设置项 heartbeat_interval，0 可关）：
Kavita 的阅读会话按相邻两次进度写入的间隔计时，只在关书推一次时长恒为 0 秒；而且它只在
pageNum / bookScrollId 真的变了才建会话、续会话，所以心跳是「位置一变就补推」而非纯定时。
书架：快照指纹不变就跳过对账；对账后后台逐本补简介 / 作者；漫画 series 的已读页回填成本地进度。
统计：纯本地确认推送（Kavita 自己按会话记录），另全量拉取服务端阅读历史 → 按「身份 × 日」的行
与替换指令写成本地统计快照；身份判定（单卷 / 多卷）与上次身份、卷名记在扩展状态文件里。
划线：epub 的划线按段落文本在本地 epub 里找锚点，新建 / 改备注推到 Kavita，注解 id 存在笔记快照里。
漫画：缓存判定 / 起始页 / 离线全归 kamare cache（03 A1），moon 只按返回码路由；
缓存不可用或失败时回退旧 cbz，再不行才下载 cbz 用内置阅读器。

@module moonsource_kavita.source
--]]

local Client = require("moonsource_kavita.client")
local Annotation = require("moonsource_kavita.annotation")
local Position = require("moonsource_kavita.position")
local Stats = require("moonsource_kavita.stats")
local Cache = require("moonsource_kavita.cache")
local VolumeList = require("moonsource_kavita.volume_list")
local SourceBase = require("source.base")
local Normalize = require("book.note.normalize")
local logger = require("utils.log")
local _ = require("gettext")
local T = require("ffi/util").template

local ID = "ext.kavita"
local PAGE_SIZE = 500
-- 书架快照格式版本：参与指纹计算。改了写入字段（如补 series / inserted_at）时 +1，
-- 让老库下次同步重对账一次，否则只在本地存过的指纹会一直跳过。
local SHELF_SNAPSHOT_VERSION = "v3"
local FORMATS = { [0] = "image", [1] = "cbz", [3] = "epub", [4] = "pdf" }
local MAGIC = { epub = "PK\3\4", cbz = "PK\3\4", pdf = "%PDF" }
-- 阅读历史分页大小（服务端上限实测 200）与页数上限：全量只有 2 页，
-- 上限只是分页头异常（缺失 / 乱报）时的兜底，不让拉取死循环。
local STATS_PAGE_SIZE = 200
local STATS_MAX_PAGES = 50
-- 统计状态文件（与书架指纹 / 回填 done 同机制）：上次身份 + 每系列章数判定 + 卷名。
local STATS_STATE_FILE = "/moonsource_kavita_stats.lua"
-- 投影预热失败只记一行：同一进程反复同步不该刷屏（项目审计口径：不静默 pcall）。
local shelf_prewarm_failed = false

---@class KavitaSource : SourceBase
---@field client KavitaClient
---@field _heartbeat KavitaHeartbeat|nil 阅读期进度心跳；无则未在跑
---@field _owner_id integer|nil 当前 Kavita 用户 id（`/api/Users/me`）；nil = 没取过 / 取不到
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return BookSourceMeta
local function meta()
    return { id = ID, name = _("Kavita"), type = "book" }
end

---@return KavitaSource
local function new()
    -- 换源 / 改配置经 Registry.reload() 重建实例：顺手丢掉旧服务器的书架投影（05 A1）。
    Cache.resetShelf()
    local settings = require("utils.settings")
    local cfg = settings.getSource(ID)
    -- 「多设备统计合并」开关已删除：Kavita 的统计以云端 reading-history 为准，本机离线差额不再补。
    -- 旧版本可能已把键落盘成 true（核心只认 == true），这里清掉，避免删了开关反而锁死在开启。
    if cfg.merge_local_stats ~= nil then
        cfg.merge_local_stats = nil
        settings.saveSource(ID)
    end
    local self = setmetatable(meta(), Source) --[[@as KavitaSource]]
    self.client = Client.new(cfg)
    return self
end

function Source:configured()
    return self.client:configured()
end

--- 能力：书架 + 统计拉取（推送是纯本地确认，见 pushStatsAsync），其余走基类默认（全 false）。
--- shelf_cache：断网时书架按适配层的缓存投影收窄可见集（05 A2）。
---@return SourceCapabilities
function Source:capabilities()
    local caps = SourceBase.capabilities(self)
    caps.stats_pull = true
    caps.shelf_cache = true
    return caps
end

--- 书架缓存投影：同步交回适配层记忆的三张表（series_ids / mark / cover）。
--- 未配置或 kamare 没给 index 时返回 nil；不触网，翻页复用同一份记忆（05 A1/A2）。
---@return ShelfCacheProjection|nil
function Source:shelfCache()
    if not self:configured() then return nil end
    return Cache.shelf()
end

---@return boolean
local function online()
    return require("ui/network/manager"):isConnected()
end

--- Kavita 标题：`-100000` 是「未命名」哨兵，纯数字卷名只是卷号。
---@param value any
---@return string|nil
local function title(value)
    if type(value) ~= "string" then return nil end
    value = require("utils.text").trim(value)
    if value == "" or value:match("^%-?%d+$") then return nil end
    return value
end

--- 文件头对得上格式才算下载完整（非 2xx 的错误页、截断的文件都过不了）。
---@param path string|nil
---@param format string|nil
---@return boolean
local function validFile(path, format)
    local file = path and io.open(path, "rb")
    if not file then return false end
    local head = file:read(4)
    file:close()
    return head == MAGIC[format]
end

---@param stable_id string
---@return string series_id, string|nil chapter_id
local function splitId(stable_id)
    local series_id, chapter_id = stable_id:match("^(%d+):(%d+)$")
    return series_id or stable_id, chapter_id
end

--- 身份对应的卷：有 chapterId 按它找，没有（series 行没下载过）且只有一卷时取唯一一卷。
---@param toc table[]
---@param chapter_id string|nil
---@return table|nil
local function findEntry(toc, chapter_id)
    if not chapter_id then return #toc == 1 and toc[1] or nil end
    for _idx, item in ipairs(toc) do
        if tostring(item.chapterId) == chapter_id then return item end
    end
    return nil
end

--- 已登记且完整的本地文件。
---@param source_id string
---@param stable_id string
---@return string|nil
local function downloaded(source_id, stable_id)
    local book = require("book.books_db").get(source_id, stable_id)
    local path = book and book.path
    if path and validFile(path, path:match("%.(%w+)$")) then return path end
    return nil
end

---@param metadata table Kavita SeriesMetadataDto
---@return string|nil
local function authorsOf(metadata)
    local authors = {}
    for _idx, writer in ipairs(metadata.writers or {}) do authors[#authors + 1] = writer.name end
    return #authors > 0 and table.concat(authors, " / ") or nil
end

--- SeriesMetadataDto 写回书库的字段（作者 / 简介 / 出版社 / 年份 / 语言）。
--- Kavita 的未知值是空串 / 0 / 空表，入库时由 BookDB 规范化丢掉。
---@param row table 至少带 source_id / stable_id
---@param metadata table
---@return table row
local function withMetadata(row, metadata)
    local publishers = {}
    for _idx, person in ipairs(metadata.publishers or {}) do publishers[#publishers + 1] = person.name end
    row.authors, row.intro = authorsOf(metadata), metadata.summary
    row.meta = {
        publisher = table.concat(publishers, " / "),
        published = metadata.releaseYear,
        language = metadata.language,
    }
    return row
end

--- Kwita 的 ISO 时间（不带时区）→ 按本地时钟解析成 epoch；解析不了返回 nil。
---@param value any
---@return integer|nil
local function parseWall(value)
    local y, mo, d, h, mi, s = tostring(value or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y or tonumber(y) < 1971 then return nil end
    return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

--- 客户端时区偏移（秒）：os.time 按本地解析 UTC 时钟得到的差值。
---@return integer
local function clientOffset()
    local now = os.time()
    return now - os.time(os.date("!*t", now) --[[@as osdate]])
end

--- `xxxUtc` 字段是真的 UTC（`2026-09-29T20:07:19.193`）：按本地解析后补回客户端偏移。
---@param value any
---@return integer|nil
local function utcTime(value)
    local t = parseWall(value)
    if not t then return nil end
    return t + clientOffset()
end

--- 服务器时区偏移（秒）：Kavita 同时给 `lastChapterAdded`（服务器本地）与
--- `lastChapterAddedUtc`（UTC），两者差值就是服务器时区（实测服务器在 UTC+8 时为 28800）。
---@param series table Kavita SeriesDto
---@return integer
local function serverOffset(series)
    local local_t, utc_t = parseWall(series.lastChapterAdded), parseWall(series.lastChapterAddedUtc)
    if not (local_t and utc_t) then return 0 end
    return local_t - utc_t
end

--- 阅读时间：`latestReadDate` 没有 Utc 后缀 —— 它是**服务器本地时间**，不是 UTC。
--- 按 UTC 解析会存成 8 小时后的「未来」时间，刚读完的书反而被它压在下面。
---@param series table Kavita SeriesDto
---@return integer|nil
local function readTime(series)
    local t = parseWall(series.latestReadDate)
    if not t then return nil end
    return t - serverOffset(series) + clientOffset()
end

--- series 的目录缓存（打开过才有）+ 其中已经在本地读过（有进度）的卷。
--- 多卷 series 的进度分别记在各卷行上（stable_id = seriesId:chapterId）：
--- 回填要跳过容器行，而读过的卷行要继承容器元数据。
---@param source_id string
---@param series_id string
---@param ProgressDB table
---@return table[]|nil toc
---@return table[] progressed 读过的卷表项
local function progressedVolumes(source_id, series_id, ProgressDB)
    local toc = require("source.toc").read(source_id, series_id)
    if type(toc) ~= "table" or #toc < 2 then return nil, {} end
    local out = {}
    for _idx, entry in ipairs(toc) do
        local chapter_id = entry.chapterId or entry.uid
        if chapter_id ~= nil and ProgressDB.get(source_id, series_id .. ":" .. tostring(chapter_id)) then
            out[#out + 1] = entry
        end
    end
    return toc, out
end

--- 卷行继承的元数据字段。
local VOLUME_META_FIELDS = { "title", "authors", "intro", "category", "series" }

--- 源这行写下去会不会真的改动库里的行。nil 字段经 COALESCE 不覆盖（同 BookDB.upsertRemote），
--- 本地脏行（sync_status=0）书库一律保留远端盖不动 —— 两种情况都不算变更。
---@param cur Book|nil 库里的卷行
---@param row table 待写的元数据字段
---@return boolean
local function untouched(cur, row)
    if not cur then return false end
    if cur.sync_status == 0 then return true end
    for _idx, field in ipairs(VOLUME_META_FIELDS) do
        if row[field] ~= nil and cur[field] ~= row[field] then return false end
    end
    return true
end

--- 卷行的元数据形状（先例 syncVolumeMeta / openBookAsync）：标题「系列 · 卷名」，其余继承容器。
--- Kavita 只在 series 级给作者 / 简介 / 分类，而展示列的是卷行：卷行空着就是「未知作者」。
--- 封面不继承：卷封面走源自己的 chapter-cover 接口。
---@param series Book|table 容器书行
---@param stable_id string "seriesId:chapterId"
---@param volume_title string|nil 卷名；拿不到时退容器名，宁可重复也不留裸 ID
---@return table
local function volumeRow(series, stable_id, volume_title)
    return {
        source_id = ID,
        stable_id = stable_id,
        title = T("%1 · %2", series.title or "", volume_title or series.title or ""),
        authors = series.authors,
        intro = series.intro,
        category = series.category,
        series = series.title,
    }
end

--- 状态文件里的卷名表（seriesId → chapterId → 卷名）规范成字符串键：dump 会把数字键写成 `[7453]`，
--- 读回来就是数字键，而条目 / 身份侧的 id 全是字符串。
---@param raw table|nil
---@return table<string, table<string, string>>
local function normalizeTitles(raw)
    local out = {}
    for series_key, names in pairs(type(raw) == "table" and raw or {}) do
        local named = {}
        if type(names) == "table" then
            for chapter_key, name in pairs(names) do
                if type(name) == "string" and name ~= "" then named[tostring(chapter_key)] = name end
            end
        end
        out[tostring(series_key)] = named
    end
    return out
end

--- 读过的卷行继承容器元数据（作者 / 简介 / 分类 / 系列）。
--- 容器补全后卷行也跟着对齐（每次同步跑一遍，幂等）。只写真会改动库的行，并把改动的行数
--- 回给调用方：对齐不算进同步变更的话，首页「当前阅读」收不到 shelf_changed，
--- 卡片会一直停在未知作者（库里其实已经补上了）。
---@param series Book|nil 容器书行
---@param series_id string
---@param entries table[] 读过的卷表项
---@return integer changed 真正改动的卷行数
local function syncVolumeMeta(series, series_id, entries)
    if not series or #entries == 0 then return 0 end
    local BookDB = require("book.books_db")
    local rows = {}
    for _idx, entry in ipairs(entries) do
        local stable_id = series_id .. ":" .. tostring(entry.chapterId or entry.uid)
        local row = volumeRow(series, stable_id, entry.title)
        if not untouched(BookDB.get(ID, stable_id), row) then
            rows[#rows + 1] = row
        end
    end
    if #rows == 0 then return 0 end
    require("book.store").rememberMany(rows)
    return #rows
end

--- 缺行卷物化：本次拉取里读到、但本机没有书行的卷补一条轻量身份行。
--- 云端读过的卷可能在本机从未下载 / 打开过：没有书行，洞察「当日书单」、单书详情（补齐才进得去）、
--- 锁屏账单就只能显示裸 ID。写入形状同卷行先例（volumeRow），书库按 upsertRemote 的默认把它落成
--- deleted=1 + sync_status=1 的隐藏身份行：不进书架、不影响对账，也压不掉本地脏行（同 untouched）。
--- 容器行缺失时跳过（连标题都拼不出来），统计行不受影响、照常落库。
--- 兜底标题（容器名）只用于新行 / 本来就是兜底的旧行：既有行的真实标题（本机开过、或上一轮
--- 用卷名物化的）不因本轮拿不到卷名而被改写。
--- 物化只服务统计展示刷新（本次同步的 stats_changed），不回调对账、不进书架同步结果。
---@param identities string[] 本次拉取出现的身份（单卷 = seriesId，多卷 = seriesId:chapterId）
---@param titles table<string, table<string, string>> seriesId → chapterId → 卷名（身份判定时记下并持久化）
---@return integer written 真正写入的行数
local function materializeVolumes(identities, titles)
    local BookDB = require("book.books_db")
    local rows = {}
    for _idx, identity in ipairs(identities) do
        local series_id, chapter_id = identity:match("^(%d+):(%d+)$")
        local series = series_id and BookDB.get(ID, series_id)
        if series then
            local named = titles[series_id]
            local volume_title = named and chapter_id and named[chapter_id]
            local row = volumeRow(series, identity, volume_title)
            local cur = BookDB.get(ID, identity)
            if volume_title or not (cur and cur.title and cur.title ~= row.title) then
                if not untouched(cur, row) then rows[#rows + 1] = row end
            end
        end
    end
    if #rows == 0 then return 0 end
    require("book.store").rememberMany(rows)
    return #rows
end

--- 服务端已读回填成本地进度（远端版，本地脏行不覆盖），书架 /「最近阅读」/「已读」都看得到。
--- Kavita 只在 series 级记 pagesRead/pages 与 latestReadDate：
---   - 漫画：series 级页数就是阅读页，本地同页不重写。
---   - 书籍：series 级页数是 spine 比例，粒度太粗；只在本地还没有这本书进度时补一条占位
---     （网页端 / 别的设备读过的书也能进「最近阅读」并标已读），绝不用它覆盖本地精确位置。
---@param source_id string
---@param series_list table[] Kavita SeriesDto
---@return integer changed
local function backfillRead(source_id, series_list)
    local ProgressDB = require("book.progress_db")
    local now = os.time()
    local changed = 0
    for _idx, series in ipairs(series_list) do
        local pages, read = tonumber(series.pages) or 0, tonumber(series.pagesRead) or 0
        if pages > 0 and read > 0 then
            local stable_id = tostring(series.id)
            local comic = tonumber(series.format) == 1
            local here = ProgressDB.get(source_id, stable_id)
            local at = readTime(series)
            -- 旧版把 latestReadDate（服务器本地时间）当 UTC 解析，存成了 8 小时后的「未来」时间，
            -- 结果刚读完的书被它挤到后面；显式拉回来（只降不升，只动干净行）。
            if here and at and (tonumber(here.updated_at) or 0) > now + 60 then
                ProgressDB.fixRemoteTime(source_id, stable_id, at)
            end
            local _toc, progressed = progressedVolumes(source_id, stable_id, ProgressDB)
            if #progressed > 0 then
                -- 读过的卷行继承容器元数据（作者 / 简介 / 分类），否则最近阅读里那几卷是未知作者。
                -- 对齐计入 changed：同步只会报「变了」的域，首页 / 图书馆据此重画。
                changed = changed + syncVolumeMeta(
                    require("book.books_db").get(source_id, stable_id), stable_id, progressed)
                -- 真实位置在卷行上；容器行保留一条服务端 series 级聚合（updated_at=0 不进最近阅读，
                -- 但书架 / 详情百分比有量级）。不再 drop：离线读、回连、再离线看到的是同一个量级。
                -- 归零必须显式允许：旧版本存过非零时间，MAX 会把它留住（US 24）。
                if ProgressDB.upsertRemote(source_id, stable_id, {
                    fraction = math.min(1, read / pages),
                    updated_at = 0,
                }, { reset_updated_at = true }) then
                    changed = changed + 1
                end
            elseif (comic and not (here and here.page == read)) or (not comic and here == nil) then
                if ProgressDB.upsertRemote(source_id, stable_id, {
                    fraction = math.min(1, read / pages),
                    page = comic and read or nil,
                    total_pages = comic and pages or nil,
                    updated_at = at,
                }) then
                    changed = changed + 1
                end
            end
        end
    end
    return changed
end

--- 后台逐本补简介 / 作者（all-v2 不带，metadata 一本一请求）。已有简介的跳过；
--- 补过的 series 记在 settings/moonsource_kavita_meta.lua（书库把空简介存成 NULL，
--- 没简介的书靠它才不会每次同步都重拉）。单本失败跳过，连续失败才当网络问题整轮收工。
---@param series_ids string[]
function Source:backfillMeta(series_ids)
    if self.backfill then self.backfill.cancel() end
    local BookDB = require("book.books_db")
    local UIManager = require("ui/uimanager")
    local state = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/moonsource_kavita_meta.lua")
    local done = state:readSetting("done", {})
    local index, fails, cancelled, job, timer = 0, 0, false, nil, nil
    local function stop()
        self.backfill = nil
        state:flush()
    end
    local function step()
        local series_id, book
        repeat
            index = index + 1
            series_id = series_ids[index]
            book = series_id and not done[series_id] and BookDB.get(self.id, series_id)
        until not series_id or (book and book.intro == nil)
        if not series_id or not online() then return stop() end
        job = self.client:json("GET", "/api/Series/metadata", { seriesId = series_id }, nil, function(metadata)
            if cancelled then return end
            if not metadata then
                -- 单本失败不拖住后面：连续失败才当网络问题整轮收工，下次同步接着补。
                fails = fails + 1
                if fails >= 3 then return stop() end
                timer = step
                UIManager:scheduleIn(0.3, timer)
                return
            end
            fails = 0
            require("book.store").rememberMany({
                withMetadata({ source_id = self.id, stable_id = series_id }, metadata),
            })
            done[series_id] = true
            timer = step
            UIManager:scheduleIn(0.3, timer)
        end)
    end
    self.backfill = { cancel = function()
        cancelled = true
        if job then job:cancel() end
        if timer then UIManager:unschedule(timer) end
        stop()
    end }
    step()
end

--- 详情页缺简介时补：series 的 metadata 写回这一行（卷行用所属 series 的）。
---@param identity BookIdentity
---@param cb fun(book: Book|nil, err: string|nil)
---@return { cancel: fun() }
function Source:getDetailAsync(identity, cb)
    return self.client:json("GET", "/api/Series/metadata", { seriesId = splitId(identity.stable_id) }, nil,
        function(metadata, err)
            if not metadata then return cb(nil, err) end
            local book = withMetadata({ source_id = self.id, stable_id = identity.stable_id }, metadata)
            require("book.store").rememberMany({ book })
            cb(book)
        end)
end

--- Kavita 的阅读会话时长 = 相邻两次进度写入的时间跨度（10 分钟无写入即封会话）。
--- 月读只在关书 / 切章 / 休眠各推一次，单次写入在 Kavita 侧就是 StartTime == EndTime 的
--- 「0 秒会话」（字数也会被 Kavita 的锚点 diff 误算成到页尾的一大段）。阅读期补推当前位置，
--- 一个阅读时段在 Kavita 侧才有多次写入、时长和字数才算得准；补推要跟在真实位置变化上
--- （见 heartbeat_interval）：Kavita 对同位置的写入直接 early-return，纯定时的整拍等于没推。
--- 会话开始时间 = 第一次有效写入，所以 heartbeat_interval 也是会话起点的最大滞后。
--- 两次补推之间的最小间隔默认值（秒），也是设置项 heartbeat_interval 的默认值。
--- 把密集翻页合并成最多一拍一次，别每页一发。0 = 关闭阅读期心跳。
local DEFAULT_HEARTBEAT_INTERVAL = 30

--- 阅读期进度心跳的补推间隔（秒）。设置项 heartbeat_interval：默认 30；
--- 0 = 关闭阅读期心跳（关书 / 切章 / 休眠的推送不受影响）。
---@return integer
local function heartbeatInterval()
    local value = tonumber(require("utils.settings").getSource(ID).heartbeat_interval)
    if value == nil then return DEFAULT_HEARTBEAT_INTERVAL end
    value = math.floor(value)
    return value > 0 and value or 0
end

---@class KavitaHeartbeat
---@field identity BookIdentity 正在读的书
---@field position ProgressPosition 最近一次事件报来的位置
---@field pushed string|nil 上次推上去的位置标识（位置没变就别推，Kavita 也会丢）
---@field last_push integer 上次补推的 Unix 时间戳（建表即当作刚推过，避开开书拉取的竞态）
---@field interval integer 本会话的补推最小间隔（秒），起心跳时从设置读入
---@field tick function 兜底定时器（慢读没有翻页事件时也定期补推）
---@field busy boolean|nil 上一拍还在飞，本拍跳过（不补报）

--- 停掉阅读期进度心跳。
---@param self KavitaSource
local function stopHeartbeat(self)
    local hb = self._heartbeat
    if not hb then return end
    self._heartbeat = nil
    require("ui/uimanager"):unschedule(hb.tick)
end

--- 位置的标识：epub 用锚点，其余用页码 / 比例。
---@param position ProgressPosition
---@return string
local function positionKey(position)
    return position.locator or tostring(position.page or position.fraction or "")
end

--- 推一次当前位置。开书拉取未落定（前 interval 秒）/ 并发 / 离线 / 距上次太近 / 位置没变，
--- 都跳过，这次的位置留给下一拍。
---@param self KavitaSource
---@param hb KavitaHeartbeat
local function pushProgress(self, hb)
    if self._heartbeat ~= hb then return end
    if hb.busy or not online() then return end
    if os.time() - hb.last_push < hb.interval then return end
    local key = positionKey(hb.position)
    if key == hb.pushed then return end
    hb.busy, hb.last_push, hb.pushed = true, os.time(), key
    logger.dbg("kavita heartbeat push", hb.identity.stable_id, key)
    self:putProgressAsync(hb.identity, hb.position, function(ok, err)
        hb.busy = false
        if ok ~= true then
            hb.pushed = nil -- 失败留个待重试的位置，下一拍再补
            logger.warn("kavita progress heartbeat failed", hb.identity.stable_id, err)
        end
    end)
end

--- 兜底拍：慢读没有翻页事件时也定期补推一次当前位置。间隔取 max(60, 补推间隔)：
--- 不会比节流间隔更频繁，设置调大后也不白醒。
---@param self KavitaSource
---@param hb KavitaHeartbeat
local function beat(self, hb)
    if self._heartbeat ~= hb then return end
    require("ui/uimanager"):scheduleIn(hb.interval, hb.tick)
    pushProgress(self, hb)
end

--- 翻页 / 切章 / 唤醒：起或续阅读期进度心跳，并更新最近位置。换书 / 间隔改了则先停旧心跳。
---@param self KavitaSource
---@param identity BookIdentity|nil
---@param position ProgressPosition|nil
local function touchHeartbeat(self, identity, position)
    if not identity or not self:configured() then return end
    local interval = heartbeatInterval()
    if interval <= 0 then
        stopHeartbeat(self)
        return
    end
    local hb = self._heartbeat
    if hb and (hb.identity.stable_id ~= identity.stable_id or hb.interval ~= interval) then
        stopHeartbeat(self)
        hb = nil
    end
    if not hb then
        hb = {
            identity = identity,
            position = position or { fraction = 0 },
            last_push = os.time(),
            interval = interval,
            tick = require("ui.guard").wrap("kavita heartbeat", function() beat(self, hb) end),
        }
        self._heartbeat = hb
        require("ui/uimanager"):scheduleIn(interval, hb.tick)
    end
    hb.identity = identity
    hb.position = position or hb.position
    -- 位置刚变过就立刻推：Kavita 认的是写入之间的跨度，定时拍若整拍都撞在同一个位置
    -- 上等于没推，会话仍会退化成 0 秒。
    pushProgress(self, hb)
end

--- 翻页 / 切章 / 唤醒起进度心跳并更新位置，关书 / 休眠停掉；其余事件交给基类。
---@param event string
---@param payload table|nil
function Source:onEvent(event, payload)
    if event == "page_changed" or event == "chapter_changed" or event == "reading_resumed" then
        if payload then touchHeartbeat(self, payload.identity, payload.position) end
        return
    end
    if event == "reading_stopped" then
        stopHeartbeat(self)
        return
    end
    return SourceBase.onEvent(self, event, payload)
end

function Source:close()
    stopHeartbeat(self)
    if self.backfill then self.backfill.cancel() end
end

--- 书架：所选库的全部 series 交给书库对账。Kavita 没有删书接口，dirty_only 跳过，
--- 本地删除留墓碑，对账不会复活。
--- 远端快照（库 + 每本 id/名称/库名/字数）的指纹没变、本地书架也非空时跳过对账：
--- 本地书架只会被对账和删除改动，删除留墓碑本来就不用对账；force 刷新照常对账。
---@param opts { dirty_only?: boolean, force?: boolean, on_progress?: fun(text: string|nil, done: integer|nil, total: integer|nil) }|nil
---@param cb fun(result: SyncResult|nil, err: any)
---@return { cancel: fun() }
function Source:syncBooksAsync(opts, cb)
    opts = opts or {}
    if opts.dirty_only then return SourceBase.skipped(cb, "no remote delete") end
    -- 手动刷新 / 书库重扫 = 05 A1 的第二类失效：投影必须重建，
    -- 否则用户点了刷新、缓存状态变了，书架标记还是旧的。后台同步复用记忆（无 TTL、不重拉）。
    if opts.force then Cache.resetShelf() end
    local libraries = {}
    for id in pairs(require("utils.settings").getSource(ID).libraries or {}) do
        libraries[#libraries + 1] = id
    end
    if not self:configured() or #libraries == 0 then
        return SourceBase.defer(cb, nil, _("请先在设置里填写 Kavita 服务器并选择书库"))
    end
    table.sort(libraries)
    local report = opts.on_progress or function() end
    local books, reads, prints, lib_index, page, cancelled =
        {}, {}, { SHELF_SNAPSHOT_VERSION, table.concat(libraries, ",") }, 1, 1, false
    ---@type HttpJob
    local job

    local function finish()
        local settings = require("utils.settings")
        local cfg = settings.getSource(ID)
        local fingerprint = require("ffi/sha2").md5(table.concat(prints, "\n"))
        local BookDB = require("book.books_db")
        local result, err, ids
        if not opts.force and cfg.shelf_fingerprint == fingerprint then
            ids = BookDB.libraryStableIdsBySource(self.id)
        end
        if ids and #ids > 0 then
            result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        else
            result, err = require("source.shelf").reconcile(self.id, books, opts.force, true)
            if not result then return cb(nil, err) end
            cfg.shelf_fingerprint = fingerprint
            settings.saveSource(ID, cfg)
            ids = {}
            for idx, book in ipairs(books) do ids[idx] = book.stable_id end
        end
        -- 简介 / 作者是逐本后台补的，跟快照变不变无关：换源 / 断网中断过，下次同步必须接着补，
        -- 否则没补到的书永远停在「未知作者」。
        self:backfillMeta(ids)
        -- 服务端已读进度同理：网页端 / 别的设备读过，书架也得进「最近阅读」与「已读」。
        result.pulled = result.pulled + backfillRead(self.id, reads)
        -- 书架投影预热：开桌面必跑本方法，进书架时命中记忆（05 A1）。失败不影响同步结果，
        -- 但不能静默：同一故障本进程只记一行（缓存模块异常通常意味着 kamare 侧坏了）。
        local ok, shelf_err = pcall(Cache.shelf)
        if not ok and not shelf_prewarm_failed then
            shelf_prewarm_failed = true
            logger.warn("kavita shelf cache prewarm failed", shelf_err)
        end
        cb(result)
    end

    local function fetch()
        report(T(_("正在拉取书架（%1 本）"), #books))
        local query = { pageNumber = page, pageSize = PAGE_SIZE }
        -- Field 19 = 库，Comparison 0 = 等于，SortField 1 = 按名称。
        local body = {
            Statements = { { Field = 19, Comparison = 0, Value = libraries[lib_index] } },
            Combination = 1,
            SortOptions = { SortField = 1, IsAscending = true },
        }
        job = self.client:json("POST", "/api/Series/all-v2", query, body, function(list, err)
            if cancelled then return end
            if not list then return cb(nil, err) end
            for _idx, series in ipairs(list) do
                books[#books + 1] = {
                    stable_id = tostring(series.id),
                    title = series.name,
                    category = series.libraryName,
                    -- Kavita 的书架一行就是一个 series：系列列填自己的名字，
                    -- 否则图书馆的「系列」页签把整库都归到「无系列」。
                    series = series.name,
                    -- 「最近添加」按 Kavita 的最近更新排，而不是全库同一次同步的上架时间。
                    -- lastChapterAddedUtc 是真的 UTC（created 没有 Utc 后缀、是服务器本地时间，不拿来做时间）。
                    inserted_at = utcTime(series.lastChapterAddedUtc),
                    meta = { words = series.wordCount },
                }
                prints[#prints + 1] = table.concat({ series.id, series.name or "", series.libraryName or "",
                    tonumber(series.wordCount) or 0, series.lastChapterAddedUtc or "" }, "\31")
                if (tonumber(series.pagesRead) or 0) > 0 then reads[#reads + 1] = series end
            end
            if #list >= PAGE_SIZE then
                page = page + 1
            elseif lib_index < #libraries then
                lib_index, page = lib_index + 1, 1
            else
                return finish()
            end
            fetch()
        end)
    end
    fetch()
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 本地统计行只在本地确认，不发请求（先例微信）。
---
--- Kavita 的阅读历史是服务端按会话自己记的，本机没有对应的上报接口；确认后这些行不再是脏行，
--- 展示仍按「云端快照 + 拉取后本地新读」合并。
--- 当场就能回也走 defer 下一帧回调（源契约）：调用方先拿到可取消句柄，取消后不再回调。
---@param rows BookStatsRow[]|nil
---@param cb fun(data: BookStatsPushResult|nil, err: string|nil)
---@return { cancel: fun() }
function Source:pushStatsAsync(rows, cb)
    local ids = {}
    for _idx, row in ipairs(rows or {}) do ids[#ids + 1] = row.id end
    return SourceBase.defer(cb, { ok = true, synced_ids = ids })
end

--- 拉取 Kavita 全局阅读历史（全量）→ reading_stats 行 + 替换指令。
---
--- 分页：`PageSize=200`，按响应头 `Pagination` 循环（页数上限兜底）；`Libraries` 必传（重复键，
--- 逗号串会被服务端当成一个库、恒返回 0 条），时区取设备时钟映射（未知回退 UTC），不带日期范围。
--- 身份：单卷系列读在 series 行、多卷逐卷（1 章 = 单卷，见 Stats），判定结果与「本次身份」记在
--- 扩展状态文件里，避免每轮重复请求目录；目录不可得的系列本轮跳过，不中断其它系列。
--- 失败一律 cb(nil, err) 静默（本地统计不受影响，下次同步自然重试），取消后不回调。
---@param cb fun(result: BookStatsPullResult|nil, err: string|nil)
---@return { cancel: fun() }
function Source:pullStatsAsync(cb)
    local libraries = {}
    for id in pairs(require("utils.settings").getSource(ID).libraries or {}) do
        libraries[#libraries + 1] = id
    end
    if not self:configured() or #libraries == 0 then
        return SourceBase.defer(cb, nil, _("请先在设置里填写 Kavita 服务器并选择书库"))
    end
    table.sort(libraries)
    local timezone = Stats.ianaTimezone(require("utils.settings").get("features.clock").timezone)
    -- 快照时刻取发起拉取的时刻：展示端以它为界把「拉取后本地新读」叠加在云端快照上。
    local fetched_at = os.time()
    local state = require("luasettings"):open(
        require("datastorage"):getSettingsDir() .. STATS_STATE_FILE)
    --- 系列 → 本地目录章数（1 = 单卷）：上次判定 + 本轮新判定，注给 Stats 用。
    --- 状态文件被写坏（不是表）时当作没判过：本轮全部重新判定，别让索引报错断掉整次拉取。
    local volumes = state:readSetting("volumes", {})
    if type(volumes) ~= "table" then volumes = {} end
    local seen = state:readSetting("identities", {})
    if type(seen) ~= "table" then seen = {} end
    -- 卷名（seriesId → chapterId → 卷名）：章数判定时目录已到手，顺带记下、随 commit 落盘。
    -- 后续轮次章数已知 → 不再读目录，物化标题靠它才不会退容器名（「系列 · 系列」）。
    local titles = normalizeTitles(state:readSetting("titles", {}))
    local entries, pending, pending_idx = {}, {}, 1
    local cancelled = false
    ---@type HttpJob|nil
    local job

    --- 终结：取消后不回调。
    local function finish(result, err)
        if cancelled then return end
        cb(result, err)
    end

    --- 身份定完 → 纯核心聚合。12 号票的「缺行卷物化」挂在这一步：身份与条目都已就绪，
    --- 物化要用的 series / 章节信息也能从同一批数据里取。
    local function build()
        local result = Stats.fromHistory(entries, {
            source_id = self.id, fetched_at = fetched_at, volumes = volumes, seen = seen,
        })
        -- 缺行卷物化（12 号票）：身份与条目都已就绪，用同一批数据补本机没有书行的卷，
        -- 展示端（洞察当日书单 / 单书详情 / 锁屏账单）才有书名。不进书架同步结果、不调对账。
        -- 不做独立变更信号：物化行只在统计视图里可见，可见的前提是同一次拉取写入了统计行 →
        -- pulled > 0 已让桌面发 stats_changed；零统计行的纯物化没有任何可见变化。
        -- 也不为此改核心：spec 硬约束「核心插件零改动，只以扩展接入既有契约」。
        materializeVolumes(result.identities, titles)
        -- 落库成功（核心的 result.commit）才更新状态：失败不前进，
        -- 上次身份还在，身份漂移留下的孤儿行下次还能清。
        result.commit = function()
            state:saveSetting("volumes", volumes)
            state:saveSetting("titles", titles)
            state:saveSetting("identities", result.identities)
            state:flush()
        end
        finish(result)
    end

    --- 逐个判定待定系列的章数：状态文件里有的不请求，缺的走 Source:toc
    --- （新鲜缓存 > 在线拉目录 > 离线过期缓存）。
    local function resolveNext()
        if cancelled then return end
        local series_id = pending[pending_idx]
        pending_idx = pending_idx + 1
        if not series_id then return build() end
        job = self:toc(series_id, function(toc, toc_err)
            if cancelled then return end
            local count = type(toc) == "table" and #toc or 0
            if count > 0 then
                volumes[series_id] = count
                -- 目录已到手：卷名顺带记下（已有的同名卷名保留：目录缓存过期时不会反而丢名字）。
                local named = titles[series_id]
                if not named then
                    named = {}
                    titles[series_id] = named
                end
                for _i, item in ipairs(toc) do
                    local chapter_id = item.chapterId or item.uid
                    if chapter_id ~= nil and item.title ~= nil then
                        named[tostring(chapter_id)] = item.title
                    end
                end
            else
                -- 判不出单卷 / 多卷的系列整条跳过：身份是错的比缺行更糟（Stats 侧也会记一条）。
                logger.warn("kavita stats series toc unavailable", series_id, toc_err)
            end
            resolveNext()
        end)
    end

    --- 一页历史。分页头不可信（缺失 / 解析不出）时按「本页拉满就还有下一页」续拉，
    --- 仍受页数上限约束，异常头不会无限循环。
    local function fetchPage(page)
        job = self.client:jsonPaged("GET", "/api/Stats/reading-history", {
            TimeZoneId = timezone, Libraries = libraries, PageNumber = page, PageSize = STATS_PAGE_SIZE,
        }, nil, function(list, err, _code, pages)
            if cancelled then return end
            if not list then return finish(nil, err) end
            for _idx, entry in ipairs(list) do entries[#entries + 1] = entry end
            local more = pages and page < pages or (not pages and #list >= STATS_PAGE_SIZE)
            if more and page < STATS_MAX_PAGES then return fetchPage(page + 1) end
            if more then logger.warn("kavita stats pull hit page cap", STATS_MAX_PAGES) end
            -- 分页合并完了才知道全量里有哪些系列：这里收集章数还不知道的，逐个判定。
            local added = {}
            for _idx, entry in ipairs(entries) do
                local series_id = entry.seriesId ~= nil and tostring(entry.seriesId) or nil
                if series_id and not volumes[series_id] and not added[series_id] then
                    added[series_id] = true
                    pending[#pending + 1] = series_id
                end
            end
            resolveNext()
        end)
    end

    fetchPage(1)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

--- series 的卷目录：series（取 libraryId）→ volumes → metadata（作者 / 简介写回书库，失败不影响目录）。
---@param series_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:fetchToc(series_id, cb)
    local cancelled = false
    ---@type HttpJob
    local job
    local function step(method, path, query, done)
        job = self.client:json(method, path, query, nil, function(data, err)
            if not cancelled then done(data, err) end
        end)
    end
    step("GET", "/api/Series/" .. series_id, nil, function(series, err)
        if not series then return cb(nil, err) end
        step("GET", "/api/Series/volumes", { seriesId = series_id }, function(volumes, verr)
            if not volumes then return cb(nil, verr) end
            local toc = {}
            for _vidx, volume in ipairs(volumes) do
                for _cidx, chapter in ipairs(volume.chapters or {}) do
                    local file = chapter.files and chapter.files[1] and chapter.files[1].filePath
                    toc[#toc + 1] = {
                        idx = #toc + 1,
                        uid = tostring(chapter.id),
                        title = title(chapter.titleName) or title(chapter.title) or title(volume.name)
                            or (file and file:match("([^/\\]+)%.[^.]+$")) or series.name,
                        chapterId = chapter.id,
                        volumeId = volume.id,
                        libraryId = series.libraryId,
                        seriesId = series.id,
                        format = FORMATS[tonumber(chapter.format) or tonumber(series.format)],
                        pages = tonumber(chapter.pages) or 0,
                        pagesRead = tonumber(chapter.pagesRead) or 0,
                    }
                end
            end
            if #toc == 0 then return cb(nil, _("这本书在 Kavita 上没有可读的卷")) end
            if not require("source.toc").put(self.id, series_id, toc) then
                return cb(nil, _("章节目录保存失败"))
            end
            step("GET", "/api/Series/metadata", { seriesId = series_id }, function(metadata)
                if metadata then
                    require("book.store").rememberMany({
                        withMetadata({ source_id = self.id, stable_id = series_id, title = series.name }, metadata),
                    })
                end
                cb(toc)
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 目录：新鲜缓存 > 在线拉取 > 离线时的过期缓存（已下载的卷离线也要能开、能记进度）。
---@param series_id string
---@param cb fun(toc: BookChapter[]|nil, err: string|nil)
---@return { cancel: fun() }
function Source:toc(series_id, cb)
    local cached = require("source.toc").read(self.id, series_id)
    if cached then return SourceBase.defer(cb, cached) end
    if online() then return self:fetchToc(series_id, cb) end
    local payload = require("book.books_db").getToc(self.id, series_id)
    local ok, stale = pcall(require("json").decode, payload or "")
    if ok and type(stale) == "table" then return SourceBase.defer(cb, stale) end
    return SourceBase.defer(cb, nil, _("网络不可用，请先连接 Wi-Fi"))
end

--- 详情页统计并入的卷身份：多卷 series 的时长 / 会话都记在 `seriesId:chapterId` 卷行上，
--- 容器（series 行）自己没有统计。目录拿不到时返回 nil，只显示本行。
---@param identity BookIdentity
---@return string[]|nil
function Source:statsIdentities(identity)
    if type(identity) ~= "table" or type(identity.stable_id) ~= "string" then return nil end
    local series_id, chapter_id = splitId(identity.stable_id)
    if chapter_id then return nil end
    local toc = require("source.toc").read(self.id, series_id)
    if not toc then
        local payload = require("book.books_db").getToc(self.id, series_id)
        local ok, decoded = pcall(require("json").decode, payload or "")
        if ok and type(decoded) == "table" then toc = decoded end
    end
    if type(toc) ~= "table" or #toc <= 1 then return nil end
    local ids = {}
    for _idx, entry in ipairs(toc) do
        if entry.chapterId ~= nil then
            ids[#ids + 1] = series_id .. ":" .. tostring(entry.chapterId)
        end
    end
    return #ids > 1 and ids or nil
end

--- 身份对应的卷。series 行的卷号取自登记的文件名（<chapterId>.<ext>）。
---@param identity BookIdentity
---@param cb fun(entry: table|nil, err: string|nil)
---@return { cancel: fun() }
function Source:entry(identity, cb)
    local series_id, chapter_id = splitId(identity.stable_id)
    if not chapter_id then
        local path = downloaded(self.id, identity.stable_id)
        chapter_id = path and path:match("(%d+)%.%w+$")
    end
    return self:toc(series_id, function(toc, err)
        if not toc then return cb(nil, err) end
        local entry = findEntry(toc, chapter_id)
        cb(entry, not entry and _("这一卷已不在 Kavita 上") or nil)
    end)
end

--- 下载一卷到 ref 的工作目录并登记路径；已下载的直接登记。
---@param ref BookIdentity
---@param entry table
---@param cb fun(path: string|nil, err: string|nil)
---@return { cancel: fun() }
function Source:fetchVolume(ref, entry, cb)
    local Paths = require("utils.paths")
    if not MAGIC[entry.format] then
        return SourceBase.defer(cb, nil, _("图片目录格式需要安装 kamare 插件在线阅读"))
    end
    Paths.ensureBookWork(ref.stable_id, self.id)
    local path = T("%1/%2.%3", Paths.bookWorkDir(ref.stable_id, self.id), entry.chapterId, entry.format)
    local function register()
        local ok, err = require("book.store").touch(path, ref)
        cb(ok and path or nil, err)
    end
    if validFile(path, entry.format) then return SourceBase.defer(register) end
    if not online() then return SourceBase.defer(cb, nil, _("网络不可用，请先连接 Wi-Fi")) end
    local dialog = require("ui.themes.widgets.progress_dialog"):new{ title = entry.title, dismissable = false }
    dialog:show()
    dialog:set(_("正在下载…"))
    local job = self.client:download(entry.chapterId, path, function(bytes, total)
        if total and total > 0 then dialog:bytes(bytes, total) end
    end, function(ok, err)
        dialog:close()
        if not ok then return cb(nil, err or _("下载失败")) end
        if not validFile(path, entry.format) then
            os.remove(path)
            return cb(nil, _("下载文件校验失败"))
        end
        register()
    end)
    return { cancel = function()
        job:cancel()
        dialog:close()
    end }
end

--- 漫画查看器的提示通道：on_next 找不到下一卷时没有 cb 可回，只能自己弹。
---@param text string
local function toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

--- 打开一卷：漫画（cbz / 图片目录）的缓存判定、起始页、离线全归 kamare cache（03 A1/A2/A9），
--- moon 只按返回码路由；其它格式仍然下载后用内置阅读器。
--- 关查看器写卷行真实位置 + 容器聚合（06 A1/A2）；章末续读按回调 id 回目录（03 A7）。
---@param ref BookIdentity 承载这一卷的书库行
---@param entry table
---@param toc table[]|nil 同 series 的卷，章末续读按 chapterId 找下一卷
---@param title string
---@param cb fun(path: string|nil, err: string|nil, meta: { handled: boolean }|nil)
---@return { cancel: fun() }
function Source:openEntry(ref, entry, toc, title, cb)
    if (entry.format ~= "cbz" and entry.format ~= "image") or not Cache.available("open") then
        return self:fetchVolume(ref, entry, cb)
    end

    local series_id = splitId(ref.stable_id)
    --- 卷身份：真实位置记在 seriesId:chapterId 上，容器行只做聚合（06 A1）。
    ---@param item table
    ---@return string
    local function volumeId(item)
        return series_id .. ":" .. tostring(item.chapterId or item.uid)
    end

    --- 聚合 = (其它已读完卷数 + 本卷 fraction) / toc 卷数；目录缺失退本卷 fraction。
    ---@param item table
    ---@param fraction number
    ---@return number
    local function aggregate(item, fraction)
        if type(toc) ~= "table" or #toc == 0 then return fraction end
        local ProgressDB = require("book.progress_db")
        local finished = 0
        for _idx, other in ipairs(toc) do
            if tostring(other.chapterId or other.uid) ~= tostring(item.chapterId or item.uid) then
                local row = ProgressDB.get(self.id, volumeId(other))
                if row and (tonumber(row.fraction) or 0) >= 1 then finished = finished + 1 end
            end
        end
        return math.min(1, (finished + fraction) / #toc)
    end

    --- 卷行缺书时用目录卷名 + 容器元数据补一条（06 A2）：ProgressDB.recent 的 EXISTS books
    --- 会过滤掉没有书行的卷，最近阅读里就看不到它。
    ---@param item table
    local function rememberVolume(item)
        local BookDB = require("book.books_db")
        local stable_id = volumeId(item)
        if BookDB.get(self.id, stable_id) then return end
        local container = BookDB.get(self.id, series_id) or ref.book or { stable_id = series_id }
        require("book.store").rememberMany({ volumeRow(container, stable_id, item.title) })
    end

    --- kamare 回调的是物理页 / 物理总数：卷行存真实位置，容器行只存聚合 fraction 且不进最近阅读。
    ---@param item table
    ---@param page any
    ---@param total any
    local function closeProgress(item, page, total)
        total = tonumber(total) or tonumber(item.pages) or 0
        page = tonumber(page) or 1
        if total <= 0 then return end
        local fraction = math.min(1, page / total)
        local ProgressDB = require("book.progress_db")
        ProgressDB.upsertRemote(self.id, volumeId(item), {
            fraction = fraction,
            page = page,
            total_pages = total,
            updated_at = os.time(),
        })
        rememberVolume(item)
        -- 容器行只做聚合；显式归零时间戳：旧版本写过的非零时间要能被清掉，
        -- 否则 series 会和卷行一起留在「最近阅读」（06 A1 / US 24）。
        ProgressDB.upsertRemote(self.id, series_id, {
            fraction = aggregate(item, fraction),
            updated_at = 0,
        }, { reset_updated_at = true })
    end

    ---@param item table
    ---@param start_page integer|nil 官方 / 旧版通道的起始页；增强版由 kamare 的 journal 决定
    ---@return table|nil viewer, string|nil code, string|nil message
    local function show(item, start_page)
        return Cache.open({
            base_url = self.client.base_url,
            api_key = self.client.api_key,
            entry = item,
            title = title,
            start_page = start_page,
            on_close = function(page, total) closeProgress(item, page, total) end,
            on_next = function(next_id)
                local next_entry = findEntry(toc or {}, tostring(next_id))
                if not next_entry then return toast(_("下一卷不在目录里")) end
                show(next_entry)
            end,
        })
    end

    local cancelled, job = false, nil

    --- 官方 / 旧版 kamare 没有 journal / resume 接口：起始页得 moon 自己给（03 A2 降级通道）。
    --- 优先问 Kavita（跨设备读到哪就从哪续）；云端没记录 / 请求失败时用本地卷行
    --- （关查看器时写的真实页），离线直接用本地。增强版由 kamare 的 journal 决定，不看这里。
    ---@param item table
    ---@param done fun(page: integer|nil)
    ---@return table|nil job
    local function withStartPage(item, done)
        local pages = math.max(1, tonumber(item.pages) or 1)
        local function localPage()
            local row = require("book.progress_db").get(self.id, volumeId(item))
            local page = row and tonumber(row.page)
            if page and page > 0 then return math.min(page, pages) end
        end
        if not online() then
            done(localPage())
            return nil
        end
        return self.client:json("GET", "/api/Reader/get-progress", { chapterId = item.chapterId }, nil,
            function(remote)
                if cancelled then return end
                local read = tonumber(remote and remote.pageNum) or 0
                if read > 0 then return done(math.min(read + 1, pages)) end
                -- 云端没记录 / 请求失败：本地关书写过页就别退回第 1 页。
                done(localPage())
            end)
    end

    ---@param viewer table|nil
    ---@param code string|nil
    ---@param message string|nil
    local function afterOpen(viewer, code, message)
        if cancelled then return end
        if viewer then return cb(nil, nil, { handled = true }) end
        if code == "offline_not_cached" then
            -- A5/A6：kamare 缓存 > 旧 cbz > 下载。旧 cbz 命中时离线照开，静默保留不删。
            local old = entry.format == "cbz" and downloaded(self.id, ref.stable_id)
            if old then return SourceBase.defer(cb, old) end
            return cb(nil, Cache.message(code, message))
        end
        if code == "viewer_running" or code == "no_pages" or code == "settings_write_failed" then
            -- 查看器已在运行绝不回退下载（旧的 bug）；页面为空 / 配置写失败也不该重下。
            return cb(nil, Cache.message(code, message))
        end
        -- 其它失败：cbz 交给 fetchVolume 兜底（本地已有文件时只登记，不重新下载）；image 下载不了。
        if entry.format == "cbz" then return self:fetchVolume(ref, entry, cb) end
        return cb(nil, Cache.message(code, message))
    end

    if Cache.enhancedOpen() then
        afterOpen(show(entry))
    else
        job = withStartPage(entry, function(start_page)
            if cancelled then return end
            afterOpen(show(entry, start_page))
        end)
    end
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job:cancel() end
    end }
end

--- 旧「已下载」标记：kamare 不可用时卷列表右侧仍要显示本地 cbz / epub。
---@param series Book
---@param entry table
---@return string|nil
local function legacyVolumeState(series, entry)
    local Paths = require("utils.paths")
    local vid = series.stable_id .. ":" .. entry.chapterId
    local state
    if entry.pages > 0 and entry.pagesRead >= entry.pages then
        state = _("已读")
    elseif entry.pagesRead > 0 then
        state = _("在读")
    end
    if entry.format and validFile(T("%1/%2.%3", Paths.bookWorkDir(vid, ID), entry.chapterId, entry.format), entry.format) then
        state = state and T(_("%1 · 已下载"), state) or _("已下载")
    end
    return state
end

--- 多卷选卷：状态字 + 行尾缓存动作，标题栏「缓存整部」（04 / 07）；关窗没选算取消。
---@param series Book
---@param toc table[]
---@param cb fun(entry: table|nil)
local function pickVolume(series, toc, cb)
    return VolumeList.pick(series, toc, cb, {
        fallback = function(entry) return legacyVolumeState(series, entry) end,
    }):show()
end

--- 打开：非漫画的已下载文件直接开（不联网）；漫画按 kamare 缓存 > 旧 cbz > 下载的顺序（03 A5）。
--- `downloaded()` 的早返回不能压过 kamare 缓存，否则有旧 cbz 的卷永远走不进离线缓存。
function Source:openBookAsync(identity, _opts, cb)
    local job, cancelled = nil, false
    local function finish(file, err, meta)
        if not cancelled then cb(file, err, meta) end
    end
    local series_id, chapter_id = splitId(identity.stable_id)
    local local_path = downloaded(self.id, identity.stable_id)
    local local_format = local_path and local_path:match("%.(%w+)$")
    -- EPUB / PDF：本地文件优先，否则下载后原生阅读；漫画要先进 kamare 判缓存（A5）。
    if local_path and local_format ~= "cbz" then return SourceBase.defer(cb, local_path) end
    job = self:toc(series_id, function(toc, err)
        if not toc then
            -- 目录拿不到但盘上有旧 cbz：本地文件仍可开，离线老用户不被缓存目录卡住。
            if local_path then return finish(local_path) end
            return finish(nil, err)
        end
        if chapter_id or #toc == 1 then
            local entry = findEntry(toc, chapter_id)
            if not entry then return finish(nil, _("这一卷已不在 Kavita 上")) end
            local name = identity.book and identity.book.title or entry.title
            job = self:openEntry(identity, entry, toc, name, finish)
            return
        end
        -- fetchToc 会把 series 级作者 / 简介写回容器行，而 identity.book 是开书那一刻的旧快照：
        -- 这里重读一次容器行，免得新 series 第一次打开时卷行被写成「未知作者」。
        local series = require("book.books_db").get(self.id, series_id)
            or identity.book or { stable_id = series_id }
        pickVolume(series, toc, function(entry)
            if cancelled then return end
            if not entry then return finish(nil, _("已取消")) end
            local ref = { source_id = self.id, stable_id = series_id .. ":" .. entry.chapterId }
            -- 卷行继承容器（series 级）元数据：Kavita 只在 series 级给作者 / 简介 / 分类，
            -- 卷行自己空着，最近阅读里就是「未知作者」。每次开书对齐一次，容器补全后立刻生效。
            require("book.store").rememberMany({ volumeRow(series, ref.stable_id, entry.title) })
            job = self:openEntry(ref, entry, toc, series.title or entry.title, finish)
        end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

---@param identity BookIdentity
---@return BookCoverRequest|nil, string|nil
function Source:coverRequest(identity)
    if not self:configured() then return nil, _("未配置") end
    local series_id, chapter_id = splitId(identity.stable_id)
    -- 已缓存系列 kamare 落了本地封面：离线也能画，且不再走鉴权 URL（05 A8）。
    -- 只在文件真的存在时用：index 里记的路径可能已被用户清掉。
    local shelf = Cache.shelf()
    local local_cover = shelf and shelf.cover and shelf.cover[series_id]
    if type(local_cover) == "string" and local_cover ~= ""
        and require("libs/libkoreader-lfs").attributes(local_cover, "mode") == "file" then
        return { url = local_cover }
    end
    local url = chapter_id and self.client:url("/api/Image/chapter-cover", { chapterId = chapter_id })
        or self.client:url("/api/Image/series-cover", { seriesId = series_id })
    return { url = url, headers = self.client:headers() }
end

--- Kavita 进度 → 月读位置；与本地同一 spine / 页时交回本地行。
---@param identity BookIdentity
---@param entry table
---@param remote { pageNum: integer, bookScrollId: string|nil }
---@return ProgressPosition
function Source:position(identity, entry, remote)
    local pages = math.max(entry.pages, 1)
    local page_num = math.min(tonumber(remote.pageNum) or 0, pages)
    local fraction = page_num / pages
    local here = require("book.progress_db").get(self.id, identity.stable_id)
    if entry.format == "epub" then
        local spine = math.min(page_num, pages - 1)
        local book = require("book.books_db").get(self.id, identity.stable_id)
        local scroll = Position.resolveScrollId(book and book.path, spine, remote.bookScrollId)
        if here and Position.spine(here.locator) == spine then
            -- 同一 spine：远端只有 spine 粒度（没带锚点 / 锚点解不出），或锚点与本机上次同步的位置
            -- 一样——Kavita 的粒度不足以把同一条内的差异判成冲突，交回本地位置，不把读者拽回节首。
            -- 只有远端锚点真的变了才用远端：网页端在同一条里往后读几页正是这种情况，
            -- 旧写法一律返回本地，core 的 synced 基线就永远看不到「云端动过」。
            local base = here.synced and here.synced.locator
            if not scroll or Position.spine(base) ~= spine or Position.toScrollId(base) == scroll then
                return here
            end
        end
        return { fraction = fraction, locator = Position.toXPointer(spine, scroll, pages) }
    end
    local page = math.max(1, math.min(page_num + 1, pages))
    if here and here.page == page then return here end
    return { fraction = fraction, page = page, total_pages = pages }
end

function Source:getProgressAsync(identity, cb)
    local job, cancelled = nil, false
    job = self:entry(identity, function(entry, err)
        if cancelled then return end
        if not entry then return cb(nil, err) end
        job = self.client:json("GET", "/api/Reader/get-progress", { chapterId = entry.chapterId }, nil,
            function(remote, perr, code)
                if cancelled then return end
                -- 没读过：旧版本回 400/404，新版本回 pageNum=0 且无锚点。
                if code == 400 or code == 404 or (remote and (tonumber(remote.pageNum) or 0) == 0
                    and not remote.bookScrollId) then
                    return cb(nil, nil, { empty = true })
                end
                if not remote then return cb(nil, perr) end
                -- page_level：远端只有 spine（epub）/ 页码（pdf）粒度，比例是「第几个 spine」，
                -- 与本地内容页比例口径不同 → core 不能按百分比判，得按 spine 判。
                cb(self:position(identity, entry, remote), nil, { page_level = true })
            end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 月读位置 → Kavita pageNum（0-based spine / 页），读完发 pages。
function Source:putProgressAsync(identity, pos, cb)
    local job, cancelled = nil, false
    job = self:entry(identity, function(entry, err)
        if cancelled then return end
        if not entry then return cb(nil, err) end
        local pages = math.max(entry.pages, 1)
        local fraction = tonumber(pos.fraction) or 0
        local page_num
        if entry.format == "epub" then
            page_num = Position.spine(pos.locator)
        elseif pos.page then
            page_num = pos.page - 1
        end
        page_num = math.max(0, math.min(page_num or math.floor(fraction * pages), pages - 1))
        if fraction >= 1 then page_num = pages end
        job = self.client:json("POST", "/api/Reader/progress", nil, {
            pageNum = page_num,
            bookScrollId = entry.format == "epub" and Position.toScrollId(pos.locator) or nil,
            chapterId = entry.chapterId,
            volumeId = entry.volumeId,
            libraryId = entry.libraryId,
            seriesId = entry.seriesId,
        }, function(data, perr)
            if not cancelled then cb(data and true, perr) end
        end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 快照里要原样带住的 Kavita 私有字段（spec §3.1）。`Normalize.clean` 是白名单，
--- 漏一个 = 该字段静默消失（比如 `kavita_comment` 丢了，下次 update 会把网页富文本清空）。
--- `pageNumber` 不是 `kavita_` 前缀，但同样是 Kavita 私有字段：它是开书定位时的 spine 提示
--- （`locateAnnotation` 读 `annotation.pageNumber`），丢了这个字段的多 spine epub 只能试第 1/2 个
--- DocFragment，第 3 个之后全部定位失败。update 时服务端忽略它，推送仍用现算的 `anchor.pageNumber`。
local KAVITA_FIELDS = {
    "pageNumber",
    "kavita_id", "kavita_note", "kavita_comment", "kavita_comment_html",
    "kavita_slot", "kavita_spoiler", "kavita_modified",
    "kavita_xpath", "kavita_ending_xpath",
    "kavita_unlocated", "kavita_deleted", "kavita_local_note",
}

--- 注解快照保留 Kavita 全字段：核心只认识 KOReader 字段，源私有字段必须自己补回。
--- 无 page 的有两类条目要放行：未定位（只有 `kavita_xpath`）与墓碑（只有 `kavita_deleted`），
--- 它们过不了 `Normalize.clean` 的「datetime + page」要求。构造期拿源坐标 / 墓碑标记当占位，
--- 清洗后再把 page 清空（同微信源的 placeholder 写法），否则一次普通保存就把它们洗掉。
---@param items table[]
---@param total_pages integer|nil
---@return table[]
function Source:cleanAnnotations(items, total_pages)
    local out = {}
    for _idx, item in ipairs(items) do
        if type(item) == "table" then
            local placeholder = not item.page and not item.pageref
                and (item.kavita_xpath or item.kavita_deleted or item.kavita_id)
            local source = item
            if placeholder then
                source = {}
                for key, value in pairs(item) do source[key] = value end
                source.page = placeholder
            end
            local clean = Normalize.clean({ source }, total_pages)[1]
            if clean then
                if placeholder then clean.page = nil end
                for _i, field in ipairs(KAVITA_FIELDS) do clean[field] = item[field] end
                out[#out + 1] = clean
            end
        end
    end
    return out
end

--- 删除墓碑（spec §9.1）：只留远端 id 与基线备注，等推送成功出列。
--- 没有 pos / page，`cleanAnnotations` 用 kavita_deleted 当占位放行，阅读器不画它。
---@param old table 上一版快照里那条
---@return table
local function tombstone(old)
    return {
        datetime = old.datetime or os.date("%Y-%m-%d %H:%M:%S"),
        chapter_idx = old.chapter_idx,
        kavita_id = old.kavita_id,
        kavita_note = old.kavita_note,
        kavita_deleted = true,
    }
end

--- 阅读器里的注解不带 Kavita id：按 pos0 从上一版快照接过来，免得每次保存都重建远端注解。
--- 另外把 `previous` 里「有 id 但没有 pos0」的条目（未定位 / 墓碑）原样搬进新 payload：
--- 它们不在阅读器快照里，不搬的话一次普通保存就把「数据在、画不出」的云端条目洗掉。
---
--- 本次被删条目（spec §9.1，仅 `index_modified < 0` 时有值）按 pos0 找回上一版那条：
--- 没坐标 / 找不到 → 只漏删不误删；没有 id → 本来就没推到远端；其余追加墓碑。
---@param previous table[]
---@param current table[]
---@param deleted table|nil KOReader 事件里的被删条目
---@return table[]
function Source:prepareLocalAnnotations(previous, current, deleted)
    current = type(current) == "table" and current or {}
    local by_pos, present = {}, {}
    for _idx, old in ipairs(previous) do
        if type(old) == "table" and old.kavita_id and old.pos0 then by_pos[old.pos0] = old end
    end
    for _idx, item in ipairs(current) do
        if item.kavita_id then present[tostring(item.kavita_id)] = true end
        local old = item.pos0 and by_pos[item.pos0]
        if old and not item.kavita_id then
            item.kavita_id, item.kavita_note = old.kavita_id, old.kavita_note
        end
    end
    for _idx, old in ipairs(previous) do
        local id = type(old) == "table" and old.kavita_id and tostring(old.kavita_id) or nil
        if id and not old.pos0 and not present[id] then
            current[#current + 1] = old
            present[id] = true
        end
    end
    if type(deleted) == "table" then
        local old = deleted.pos0 and by_pos[deleted.pos0] or nil
        if not old then
            -- pos0 对不上（换过文件版本）或事件里没坐标：记一条，下一次开书远端那条会回来。
            logger.warn("kavita annotation deleted without anchor; skip tombstone", tostring(deleted.text))
        elseif not old.kavita_id then
            logger.dbg("kavita annotation deleted before push; no tombstone", tostring(deleted.text))
        elseif not present[tostring(old.kavita_id)] then
            current[#current + 1] = tombstone(old)
            present[tostring(old.kavita_id)] = true
        end
    end
    return current
end

--- 远端删除回流（spec §9.2）：`seen` 按 pull 回来的**全量** id 建（含未定位），
--- 输出只画可渲染的远端条目；本地条目带 `kavita_id` 而远端集合里没有 → 丢弃并计入 `dropped`。
--- 远端同键多条（历史推送窗口的产物，spec §6 / §13.1 B「同键取 id 最小」）只画 id 最小那条，
--- 其余被抑制、计入 `deduped`；被抑制的 id 仍留在 `seen_id`（远端没删它，本地副本不算 dropped）。
--- 未定位条目仍占 id，所以它对应的本地副本不会被当成远端已删；纯本地划线（无 id）原样保留。
--- `authoritative` 恒 false（spec §7），这里不改变语义，保留参数只为统一签名。
---@param remote table[]
---@param current table[]
---@param paging boolean|nil
---@param _authoritative boolean|nil
---@return table[] merged
---@return integer dropped 远端已删（本地有 id 但远端全量里没有）
---@return integer deduped 远端同键被抑制（不画）的条数
function Source:mergeAnnotations(remote, current, paging, _authoritative)
    local merged, seen_id, shown_id, seen_pos, suppressed, suppressed_id = {}, {}, {}, {}, {}, {}
    local list = type(remote) == "table" and remote or {}

    -- 第一遍：建远端全量 id 集合（含之后要被抑制的），并按键挑出每条键要画的那条。
    -- 键与推送侧认领同一条（Annotation.key 两套字段名都认）；同键取 id 最小，没有 id 的排最后。
    local winner = {}
    for idx, item in ipairs(list) do
        if type(item) == "table" then
            local id = tonumber(item.kavita_id)
            if id then seen_id[id] = true end
            if Normalize.renderable(item, paging) then
                local key = Annotation.key(item)
                local best = winner[key]
                if best == nil then
                    winner[key] = idx
                else
                    local best_id = tonumber(list[best].kavita_id) or math.huge
                    if (id or math.huge) < best_id then
                        suppressed[best] = true
                        winner[key] = idx
                    else
                        suppressed[idx] = true
                    end
                end
            end
        end
    end
    local deduped = 0
    for idx in pairs(suppressed) do
        deduped = deduped + 1
        local id = tonumber(list[idx].kavita_id)
        if id then suppressed_id[id] = true end
    end

    -- 第二遍：按原顺序输出保留下来的远端条目（顺序影响绘制顺序，不因去重打乱）。
    for idx, item in ipairs(list) do
        if type(item) == "table" and not suppressed[idx] and Normalize.renderable(item, paging) then
            local id = tonumber(item.kavita_id)
            merged[#merged + 1] = item
            if id then shown_id[id] = true end
            if type(item.pos0) == "string" then
                seen_pos[item.pos0 .. Annotation.KEY_SEP .. tostring(item.pos1)] = true
            end
        end
    end
    local dropped = 0
    for _idx, item in ipairs(type(current) == "table" and current or {}) do
        if type(item) == "table" then
            local id = tonumber(item.kavita_id)
            if id and not seen_id[id] then
                dropped = dropped + 1
                logger.warn("kavita annotation deleted remotely; drop local", id)
            else
                -- 远端已定位的那条会带着复用来的旧 pos0：同 id / 同坐标只画远端那份。
                -- id 在远端全量里但没画出来（未定位）→ 本地这份必须保留，否则书里就少一条。
                -- 例外：id 在远端被同键抑制 → 远端画的是同键里 id 最小的那条，本地这份不能再画一遍。
                local pos_key = type(item.pos0) == "string"
                    and (item.pos0 .. Annotation.KEY_SEP .. tostring(item.pos1)) or nil
                local duplicate = (id and shown_id[id])
                    or (id and suppressed_id[id])
                    or (item.drawer and pos_key and seen_pos[pos_key])
                if not duplicate and Normalize.renderable(item, paging) then
                    merged[#merged + 1] = item
                end
            end
        end
    end
    return merged, dropped, deduped
end

-- ---------------------------------------------------------------------------
-- 开书定位：云端注解（元素级 xPath + selectedText）→ crengine xpointer（spec §4）
--
-- Kavita 只给元素路径，没有偏移；文档接口又没有「节点+偏移 → xpointer」。
-- 所以反过来让 crengine 当文本真值来源：逐个 text()[k] 取节点文本，在元素拼接文本里
-- 找 selectedText，再把字节区间映射回 (k, codepoint offset)。合成后必须回读校验，
-- 绝不把没验过的坐标写进 doc_settings（错位的划线比不画更糟）。
-- ---------------------------------------------------------------------------

--- crengine 的 `.N` 单位是 codepoint（lChar32），不是 UTF-8 字节；
--- LuaJIT 没有 utf8 库，只能数前导字节。
---@param s string
---@return integer
local function codepointLength(s)
    local count, i, len = 0, 1, #s
    while i <= len do
        local byte = s:byte(i)
        if byte < 0x80 or byte >= 0xC0 then count = count + 1 end
        i = i + 1
    end
    return count
end

---@param s string
---@param i integer
---@return integer
local function charStep(s, i)
    local byte = s:byte(i)
    if byte < 0x80 then return 1 end
    if byte < 0xE0 then return 2 end
    if byte < 0xF0 then return 3 end
    return 4
end

--- 前 count 个 codepoint 占用的字节数（1-based 最后字节位置，count=0 时为 0）。
---@param s string
---@param count integer
---@return integer
local function bytePosOfCodepoint(s, count)
    local seen, i = 0, 1
    while seen < count and i <= #s do
        i = i + charStep(s, i)
        seen = seen + 1
    end
    return i - 1
end

--- 按 codepoint 取子串（1-based，含首含尾）。
---@param s string
---@param from integer
---@param to integer
---@return string
local function codepointSub(s, from, to)
    local byte_start = bytePosOfCodepoint(s, from - 1) + 1
    local byte_end = bytePosOfCodepoint(s, to)
    return s:sub(byte_start, byte_end)
end

--- 空白判定：ASCII 折叠 + NBSP + 全角空格。crengine 的 CSS 空白处理会动这三类，
--- 真实样本跨段回读只差空白，所以去空白重试必须把它们都算进去。
---@param s string
---@param i integer
---@return integer 该字符占用的字节数；0 = 不是空白
local function whitespaceAt(s, i)
    local byte = s:byte(i)
    if byte == 0x20 or byte == 0x09 or byte == 0x0A or byte == 0x0D then return 1 end
    if byte == 0xC2 and s:byte(i + 1) == 0xA0 then return 2 end
    if byte == 0xE3 and s:byte(i + 1) == 0x80 and s:byte(i + 2) == 0x80 then return 3 end
    return 0
end

--- 去空白并保留「过滤后字节 → 原字节」映射，命中后能把偏移回算到原文本。
---@param s string
---@return string, table<integer, integer>
local function stripWhitespace(s)
    local out, map = {}, {}
    local i, len = 1, #s
    while i <= len do
        local width = whitespaceAt(s, i)
        if width > 0 then
            i = i + width
        else
            out[#out + 1] = s:sub(i, i)
            map[#out] = i
            i = i + 1
        end
    end
    return table.concat(out), map
end

--- 最后一个非空白字符的字节位置（跨段「贴元素末尾」判定用；全空白回 0）。
---@param s string
---@return integer
local function trimEndByte(s)
    local i, last = 1, 0
    while i <= #s do
        local width = whitespaceAt(s, i)
        if width == 0 then
            i = i + charStep(s, i)
            last = i - 1
        else
            i = i + width
        end
    end
    return last
end

--- 第一个非空白字符的字节位置（跨段「贴元素开头」判定用）。
---@param s string
---@return integer
local function trimStartByte(s)
    local i = 1
    while i <= #s do
        local width = whitespaceAt(s, i)
        if width == 0 then break end
        i = i + width
    end
    return i
end

---@param document table
---@param xp string
---@return string|nil
local function nodeText(document, xp)
    local ok, text = pcall(document.getTextFromXPointer, document, xp)
    if ok and type(text) == "string" then return text end
    return nil
end

--- 逐 text()[k] 取节点文本：crengine 的 `text()` 不带下标在多节点时会失败，
--- 所以合成路径一律写到 `[k]`；空节点跳过（否则字节区间会映射到零长度节点上）。
---@param document table
---@param element string
---@return { k: integer, text: string }[]
local function textNodes(document, element)
    local nodes = {}
    for k = 1, 128 do
        local text = nodeText(document, element .. "/text()[" .. k .. "]")
        if not text then break end
        if text ~= "" then nodes[#nodes + 1] = { k = k, text = text } end
    end
    return nodes
end

---@param nodes { k: integer, text: string }[]
---@return string
local function concatNodes(nodes)
    local parts = {}
    for _idx, node in ipairs(nodes) do parts[#parts + 1] = node.text end
    return table.concat(parts)
end

--- 拼接文本里的字节区间 → (text()[k], codepoint offset)。
---@param nodes { k: integer, text: string }[]
---@param start_byte integer 1-based，区间首字节
---@param end_byte integer 1-based，区间尾字节
---@return integer|nil, integer|nil, integer|nil, integer|nil
local function mapRange(nodes, start_byte, end_byte)
    local acc, k0, off0, k1, off1 = 0, nil, nil, nil, nil
    for _idx, node in ipairs(nodes) do
        local seg_start, seg_end = acc + 1, acc + #node.text
        if not k0 and start_byte >= seg_start and start_byte <= seg_end then
            k0 = node.k
            off0 = codepointLength(node.text:sub(1, start_byte - seg_start))
        end
        if end_byte >= seg_start and end_byte <= seg_end then
            k1 = node.k
            off1 = codepointLength(node.text:sub(1, end_byte - seg_start + 1))
        end
        acc = seg_end
    end
    return k0, off0, k1, off1
end

--- 在元素文本里找 selectedText：先精确找，失败再去空白找（CSS 空白折叠差异）。
--- 同段重复文本取第一处（真实样本 0/29 歧义），由回读校验兜住错位。
---@param document table
---@param element string
---@param selected string
---@return string|nil level "exact"|"wsnorm"|nil
---@return { k: integer, text: string }[] nodes
---@return string concat
---@return integer|nil start_byte
---@return integer|nil end_byte
local function locateInElement(document, element, selected)
    local nodes = textNodes(document, element)
    if #nodes == 0 then
        return nil, nodes, "", nil, nil
    end
    local concat = concatNodes(nodes)
    local start_byte = concat:find(selected, 1, true)
    if start_byte then
        return "exact", nodes, concat, start_byte, start_byte + #selected - 1
    end
    local flat, map = stripWhitespace(concat)
    local wanted = stripWhitespace(selected)
    local flat_start = wanted ~= "" and flat:find(wanted, 1, true) or nil
    if flat_start then
        return "wsnorm", nodes, concat, map[flat_start], map[flat_start + #wanted - 1]
    end
    return nil, nodes, concat, nil, nil
end

--- 起始元素里的最长可命中前缀。跨段选区的头半截在起点段落里可能不是完整 selectedText，
--- 所以从全长往短里试；同一前缀出现多次时优先取「贴元素末尾」的那次（选区的头必然贴段尾）。
---@param document table
---@param element string
---@param selected string
---@return string|nil concat
---@return table|nil nodes
---@return integer|nil start_byte
---@return integer|nil end_byte
local function locatePrefix(document, element, selected)
    local nodes = textNodes(document, element)
    if #nodes == 0 then return nil end
    local concat = concatNodes(nodes)
    local total = codepointLength(selected)
    local element_end = trimEndByte(concat)
    for take = total, 1, -1 do
        local prefix = codepointSub(selected, 1, take)
        local first = concat:find(prefix, 1, true)
        if first then
            local chosen = first
            local pos = 1
            while true do
                local hit = concat:find(prefix, pos, true)
                if not hit then break end
                if hit + #prefix - 1 == element_end then chosen = hit end
                pos = hit + 1
            end
            return concat, nodes, chosen, chosen + #prefix - 1
        end
    end
    return nil
end

--- 终点元素里的最长可命中后缀。同理，优先取「从元素开头起」的那次（选区尾必然贴段首）。
---@param document table
---@param element string
---@param selected string
---@return string|nil concat
---@return table|nil nodes
---@return integer|nil start_byte
---@return integer|nil end_byte
local function locateTail(document, element, selected)
    local nodes = textNodes(document, element)
    if #nodes == 0 then return nil end
    local concat = concatNodes(nodes)
    local total = codepointLength(selected)
    local element_start = trimStartByte(concat)
    for take = total, 1, -1 do
        local suffix = codepointSub(selected, total - take + 1, total)
        local first = concat:find(suffix, 1, true)
        if first then
            local chosen = first
            local pos = 1
            while true do
                local hit = concat:find(suffix, pos, true)
                if not hit then break end
                if hit == element_start then chosen = hit end
                pos = hit + 1
            end
            return concat, nodes, chosen, chosen + #suffix - 1
        end
    end
    return nil
end

--- Kavita `//body/p[9]` → `/body/DocFragment[N]/body/p[9]`；N = spine + 1。
--- 只削一个 `/` 补前缀，不自己归一 `[1]` 下标（那是 DOM version 的事）。
---@param xpath string|nil
---@param fragment integer
---@return string|nil
local function fragmentBase(xpath, fragment)
    if type(xpath) ~= "string" or xpath == "" then return nil end
    local path = xpath
    if path:sub(1, 2) == "//" then
        path = path:sub(2)
    elseif path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    -- Kavita 不会给 DocFragment；真给了就原样用（跨 spine 的 endingXPath 也不至重复加前缀）。
    if path:sub(1, 17) == "/body/DocFragment" then return path end
    if path:sub(1, 5) ~= "/body" then return nil end
    return "/body/DocFragment[" .. fragment .. "]" .. path
end

---@param document table
---@param xp string
---@return boolean
local function inDocument(document, xp)
    local ok, present = pcall(document.isXPointerInDocument, document, xp)
    return ok and present == true
end

--- 同片段同级回扫：Kavita 的 `p[k]` 与 crengine 的元素数可能不同（HTML 自动闭合、
--- 表格 foster parenting），下标失配时在同一父节点下扫同名兄弟，以文本为准找回。
---@param document table
---@param element string
---@param selected string
---@return string|nil element
---@return table|nil nodes
---@return integer|nil start_byte
---@return integer|nil end_byte
local function scanSiblings(document, element, selected)
    local tag = element:match("([^/%[]+)%[%d+%]$")
    local parent = element:match("^(.*)/[^/]+$")
    if not tag or not parent then return nil end
    for index = 1, 400 do
        local candidate = parent .. "/" .. tag .. "[" .. index .. "]"
        if not nodeText(document, candidate) then break end
        local level, nodes, _concat, start_byte, end_byte = locateInElement(document, candidate, selected)
        if level then
            return candidate, nodes, start_byte, end_byte
        end
    end
    return nil
end

--- 合成坐标的唯一成功判据：两端都在文档里，且回读文本与 selectedText 相等（允许空白差异）。
--- 只信 isXPointerInDocument 不够——路径能解析不代表画出来的就是这段文字。
---@return boolean, string|nil reason
local function verifySelection(document, pos0, pos1, selected)
    if not inDocument(document, pos0) then return false, "pos0-missing" end
    if not inDocument(document, pos1) then return false, "pos1-missing" end
    if type(document.getTextFromXPointers) ~= "function" then return true end
    local ok, got = pcall(document.getTextFromXPointers, document, pos0, pos1)
    if not ok then return true end -- 老文档 / 桩没实现：不要因校验器缺失把能画的全判失败
    if type(got) ~= "string" then return true end
    if got == selected then return true end
    if stripWhitespace(got) == stripWhitespace(selected) then return true end
    return false, "text-mismatch"
end

--- 跨段：起点取最长可命中前缀、终点取最长可命中后缀，再各自映射回文本节点。
---@param document table
---@param head_element string
---@param tail_element string
---@param selected string
---@return { pos0: string, pos1: string }|nil
local function locateCross(document, head_element, tail_element, selected)
    local _head_concat, head_nodes, head_start, head_end = locatePrefix(document, head_element, selected)
    if not head_nodes then return nil end
    local _tail_concat, tail_nodes, tail_start, tail_end = locateTail(document, tail_element, selected)
    if not tail_nodes then return nil end
    local k0, off0 = mapRange(head_nodes, head_start, head_end)
    local _tail_k, _tail_off, k1, off1 = mapRange(tail_nodes, tail_start, tail_end)
    if not k0 or not k1 then return nil end
    return {
        pos0 = head_element .. "/text()[" .. k0 .. "]." .. off0,
        pos1 = tail_element .. "/text()[" .. k1 .. "]." .. off1,
    }
end

--- 在指定 DocFragment 上尝试一条注解（不含滑窗）。
---@return { pos0: string, pos1: string }|nil, string|nil reason
local function attemptLocalize(document, annotation, fragment)
    local selected = annotation.text
    if type(selected) ~= "string" or selected == "" then return nil, "no-text" end
    local base = fragmentBase(annotation.kavita_xpath, fragment)
    if not base then return nil, "bad-xpath" end
    local ending = annotation.kavita_ending_xpath
    local cross = type(ending) == "string" and ending ~= "" and ending ~= annotation.kavita_xpath
    if cross then
        local tail_base = fragmentBase(ending, fragment)
        if tail_base then
            local located = locateCross(document, base, tail_base, selected)
            if located and verifySelection(document, located.pos0, located.pos1, selected) then
                return located
            end
        end
        -- endingXPath 不可用或起点其实含全文：退回单元素匹配，仍以回读为准。
    end

    local used, nodes, start_byte, end_byte
    local level, found_nodes, _concat, found_start, found_end = locateInElement(document, base, selected)
    if level then
        used, nodes, start_byte, end_byte = base, found_nodes, found_start, found_end
    else
        local candidate, sibling_nodes, sibling_start, sibling_end = scanSiblings(document, base, selected)
        if candidate then
            used, nodes, start_byte, end_byte = candidate, sibling_nodes, sibling_start, sibling_end
        end
    end
    if not used then return nil, "text-not-found" end
    local k0, off0, k1, off1 = mapRange(nodes, start_byte, end_byte)
    if not k0 or not k1 then return nil, "range-map" end
    local pos0 = used .. "/text()[" .. k0 .. "]." .. off0
    local pos1 = used .. "/text()[" .. k1 .. "]." .. off1
    local ok, reason = verifySelection(document, pos0, pos1, selected)
    if not ok then return nil, reason end
    return { pos0 = pos0, pos1 = pos1 }
end

--- pageNumber 只当提示（Kavita 旧推送窗口会差一位，实测 6/29），
--- 依次试 spine / spine+1 / spine−1，每跳都要求文本命中且回读通过。
---@return { pos0: string, pos1: string }|nil, string|nil reason
local function locateAnnotation(document, annotation)
    local hint = math.floor(tonumber(annotation.pageNumber) or 0)
    local fragment = hint + 1
    local last_reason
    for _idx, delta in ipairs({ 0, 1, -1 }) do
        local candidate = fragment + delta
        if candidate >= 1 then
            local located, reason = attemptLocalize(document, annotation, candidate)
            if located then return located end
            last_reason = reason or last_reason
        end
    end
    return nil, last_reason or "text-not-found"
end

---@param document table
---@param xp string
---@return string
local function normalizedXP(document, xp)
    if type(document.getNormalizedXPointer) ~= "function" then return xp end
    local ok, normalized = pcall(document.getNormalizedXPointer, document, xp)
    if ok and type(normalized) == "string" and normalized ~= "" then return normalized end
    return xp
end

---@param document table
---@param xp string
---@return integer|nil
local function pageOf(document, xp)
    if type(document.getPageFromXPointer) ~= "function" then return nil end
    local ok, page = pcall(document.getPageFromXPointer, document, xp)
    if ok and tonumber(page) then return tonumber(page) end
    return nil
end

--- 把云端注解定位到当前打开的文档；返回**全量**（含未定位）。
---
--- 返回 nil 表示「本次不应用」：无文档 / html_path 缺失或文件不在 / 文档不是这本书。
--- core 的 applySnapshot 见到 nil 会直接放弃，绝不覆盖 doc_settings —— 这条比多画几条更重要。
--- 未定位条目只打 `kavita_unlocated`、不写占位坐标，merge 才不会把它误判成「远端已删」。
---
--- 复用放在最前：同一 `kavita_id` 已有 pos0/pos1 且仍通过 isXPointerInDocument 的，
--- 直接用旧坐标，避免每次开书重算（也避免文本微调后坐标抖动）。
---
---@param document table|nil     已打开的 crengine 文档
---@param annotations table[]    pull 落的原始条目
---@param html_path string|nil   已落盘的 epub 路径（只查存在性，绝不读 ZIP 字节）
---@param current table[]|nil    阅读器当前注解
---@return table[]|nil
function Source:localizeAnnotations(document, annotations, html_path, current)
    if type(document) ~= "table"
        or type(document.getTextFromXPointer) ~= "function"
        or type(document.isXPointerInDocument) ~= "function" then
        return nil
    end
    if type(html_path) ~= "string" or html_path == "" then return nil end
    -- html_path 就是 core 传进来的 ui.document.file；两者不一致说明这次快照不是这本书的
    -- （派生笔记 / 切书竞态），宁可不动，也不要把这本书的坐标写到另一本书的 doc_settings。
    if type(document.file) == "string" and document.file ~= "" and document.file ~= html_path then
        return nil
    end
    if require("libs/libkoreader-lfs").attributes(html_path, "mode") ~= "file" then return nil end
    if type(annotations) ~= "table" then return {} end

    local reusable = {}
    for _idx, item in ipairs(type(current) == "table" and current or {}) do
        if type(item) == "table" and item.kavita_id and type(item.pos0) == "string"
            and type(item.pos1) == "string" and inDocument(document, item.pos0)
            and inDocument(document, item.pos1) then
            local key = tostring(item.kavita_id)
            reusable[key] = reusable[key] or item
        end
    end

    local out, unlocated, last_reason = {}, 0, nil
    for _idx, item in ipairs(annotations) do
        local ann = item
        if type(item) == "table" then
            -- 浅拷贝：定位只补坐标，pull 落的字段（备注 / 颜色 / 时间）原样带住。
            ann = {}
            for key, value in pairs(item) do ann[key] = value end
            local saved = item.kavita_id and reusable[tostring(item.kavita_id)] or nil
            if saved then
                ann.pos0, ann.pos1 = saved.pos0, saved.pos1
                ann.page = saved.page or saved.pos0
                ann.pageno = saved.pageno or pageOf(document, saved.pos0)
                ann.kavita_unlocated = nil
            else
                local located, reason = locateAnnotation(document, ann)
                if located then
                    local pos0 = normalizedXP(document, located.pos0)
                    local pos1 = normalizedXP(document, located.pos1)
                    ann.pos0, ann.pos1 = pos0, pos1
                    -- page 填 pos0 字符串（照抄本地真实条目）：数字会被 normalize 当成分页文档。
                    ann.page = pos0
                    ann.pageno = pageOf(document, pos0)
                    ann.kavita_unlocated = nil
                else
                    ann.pos0, ann.pos1, ann.page, ann.pageno = nil, nil, nil, nil
                    ann.kavita_unlocated = true
                    unlocated = unlocated + 1
                    last_reason = reason or last_reason
                end
            end
        end
        out[#out + 1] = ann
    end

    -- 失败只记一条汇总，别让一本定位不了的书刷满日志。
    if unlocated > 0 then
        logger.warn("kavita annotation localize failed", html_path,
            unlocated .. "/" .. #annotations, last_reason or "text-not-found")
    end
    return out
end

--- 颜色槽位 → KOReader 颜色名（01 §Answer）：Kavita 只存用户调色板的槽位序号，
--- api key 客户端读不到 palette，按索引约定映射；越界 / 未知回落 yellow（0）。颜色不参与同一性。
local SLOT_COLORS = { [0] = "yellow", [1] = "green", [2] = "blue", [3] = "orange", [4] = "purple" }

---@param slot any
---@return string
local function slotColor(slot)
    return SLOT_COLORS[tonumber(slot) or 0] or "yellow"
end

--- Kavita AnnotationDto → notes payload 条目（spec §3.1 / §3.2）。
--- 只落数据，不算坐标：`page` / `pos0` / `pos1` 是开书时 localizeAnnotations 的产物（05 §3）。
--- `pageNumber` 只落成本地定位提示（0-based spine）：`locateAnnotation` 用它挑 DocFragment，
--- update 时 Kavita 服务端忽略这个字段，推送坐标仍用现算的 `anchor.pageNumber`。
---@param dto table
---@return table|nil
local function annotationPayload(dto)
    -- 没有 id 才真的对不上任何本地条目（update / delete 的唯一依据），直接丢。
    if dto.id == nil or dto.id == "" then return nil end
    local text = dto.selectedText
    -- 没有选中文本的条目（Kavita 自己也不许这么建）画不出来，但**保留成未定位占位**：
    -- 它的 id 必须进远端全量集合，否则 mergeAnnotations 会把本地带该 id 的那条当成「远端已删」抹掉。
    local blank = type(text) ~= "string" or require("utils.text").trim(text) == ""
    if blank then text = "" end
    local drawer
    if not blank then drawer = "lighten" end
    -- note 与 kavita_note 必须来自同一次读回：两侧一旦有差异，推送侧每轮都会判「备注改过」。
    -- 空备注落 nil，不落 ""：KOReader 的 getBookmarkType 把 "" 当真值（`if bookmark.note then
    -- return "note"`），默认 bookmarks_items_text_type = "note" 会把这条渲染成空行。
    -- 本地高亮本来就是 nil；sameNote(nil, "") 仍判等，推送侧不会误判「改过」。
    local note = Annotation.noteText(dto.comment, dto.commentHtml, dto.commentPlainText)
    if note == "" then note = nil end
    -- createdUtc 是真正的 UTC；解析不出（如 0001 占位）回退当前时间，只影响显示 / 排序。
    local created = utcTime(dto.createdUtc)
    return {
        datetime = os.date("%Y-%m-%d %H:%M:%S", created or os.time()),
        drawer = drawer,
        color = slotColor(dto.selectedSlotIndex),
        text = text,
        note = note,
        pageNumber = tonumber(dto.pageNumber) or 0,
        kavita_id = dto.id,
        kavita_note = note,
        kavita_comment = dto.comment,
        kavita_comment_html = dto.commentHtml,
        kavita_slot = dto.selectedSlotIndex,
        kavita_spoiler = dto.containsSpoiler,
        kavita_modified = dto.lastModifiedUtc,
        kavita_xpath = dto.xPath,
        kavita_ending_xpath = dto.endingXPath,
        kavita_unlocated = blank or nil,
    }
end

--- 当前用户 id：注解列表在账号开了「查看他人注解」时会混入别人的条目，
--- 拉取必须按 `ownerUserId` 收窄，否则本地落一堆别人的划线、推送删改还会整批 400。
--- 取不到（老版本 / 无权限）就降级为不过滤并记日志：多看到自己的不会丢数据，漏过滤别人的才会误删。
---@param source KavitaSource
---@param cb fun(owner_id: integer|nil)
---@return HttpJob
local function ownerIdAsync(source, cb)
    if source._owner_id ~= nil then return SourceBase.defer(cb, source._owner_id) end
    return source.client:json("GET", "/api/Users/me", nil, nil, function(data, err)
        local id = type(data) == "table" and tonumber(data.id) or nil
        if not id then
            logger.warn("kavita annotation owner unknown; pull without owner filter", err)
            return cb(nil)
        end
        source._owner_id = id
        cb(id)
    end)
end

--- 开书时全量拉取云端 epub 注解（spec §3.4）：只落数据、不定位，坐标留给开书时的文档。
--- 每章一次 `GET /api/Annotation/all`（单文件 epub 即一本书一个 chapter），与推送各发一次、不做缓存。
--- `pageNumber` 是 localizeAnnotations 的 spine 提示，不是坐标：update 时服务端忽略它，
--- 推送仍用现算的 `anchor.pageNumber`（spec §8.4）。
--- `authoritative` 恒 false：远端为空不代表本地该清空，删除语义不归这里。
--- 失败回 `cb(nil, err)`，notes 表快照原样（离线开书只记日志）。
---@param identity BookIdentity
---@param cb fun(annotations: table[]|nil, err: string|nil, meta: {authoritative: boolean}|nil)
---@return { cancel: fun() }
function Source:pullNotesAsync(identity, cb)
    local job, cancelled = nil, false
    local function finish(annotations, err, meta)
        if not cancelled then cb(annotations, err, meta) end
    end
    job = self:entry(identity, function(entry, err)
        if cancelled then return end
        if not entry then return finish(nil, err) end
        -- 非 epub 没有 Kavita 注解（与推送侧短路一致）：零请求。
        if entry.format ~= "epub" then return finish({}, nil, { authoritative = false }) end
        job = ownerIdAsync(self, function(owner_id)
            if cancelled then return end
            job = Annotation.listByChapter(self.client, entry.chapterId, owner_id, function(list, lerr)
                if cancelled then return end
                if not list then return finish(nil, lerr) end
                local annotations = {}
                for _idx, dto in ipairs(list) do
                    local annotation = annotationPayload(dto)
                    if annotation then annotations[#annotations + 1] = annotation end
                end
                finish(annotations, nil, { authoritative = false })
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- Kavita 的 highlightCount 按 UTF-16 码元计。
---@param s string
---@return integer
local function utf16Length(s)
    local n = 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + (#ch == 4 and 2 or 1) end
    return n
end

--- 这一条要不要推：没 id 的本地新划线，或备注与上次同步的基线不同。
--- 书签（没有 drawer）与墓碑不走这里。
---@param ann table
---@return boolean
local function needsPush(ann)
    if not (ann.drawer and type(ann.pos0) == "string" and type(ann.text) == "string") then return false end
    if not ann.kavita_id then return true end
    return not Annotation.sameNote(ann.note, ann.kavita_note)
end

--- 划线推到 Kavita：先按章对账一次，再逐条新建 / 更新，远端 id 原地回填给核心落库。
---
--- 幂等的真相源是「每次推送前按章拉一遍远端注解」，payload 里的 kavita_id 只是快路径：
--- 上传期间用户又划线（stale）、workdir 清空、pos0 漂移都靠下一轮对账自愈，不需要本地映射文件。
--- 全有或全无：任一写请求失败就整批报错留脏（已建成的条目下轮按内容键认领，不会重复建）。
--- 先写后删（spec §9.4）：墓碑的 id 先从对账列表里剔掉（防同键认领），全部写成功后再一次 bulk-delete。
---@param identity BookIdentity
---@param annotations table[]
---@param cb fun(ok: boolean|nil, err: string|nil, data: { pushed: integer, adopted: integer, conflicts: integer, deleted: integer }|nil)
---@return { cancel: fun() }
function Source:pushNotesAsync(identity, annotations, cb)
    local job, cancelled = nil, false
    job = self:entry(identity, function(entry, err)
        if cancelled then return end
        if not entry then return cb(nil, err) end
        if entry.format ~= "epub" then return cb(true, nil, { pushed = 0, deleted = 0 }) end
        local path = downloaded(self.id, identity.stable_id)

        -- 墓碑（kavita_deleted + id）不推、也不许被认领：删了又原地划一条同键的，
        -- 认领会把它挂到马上要删的那条上。
        local tombstoned, pending = {}, {}
        for _idx, ann in ipairs(annotations) do
            local dead_id = ann.kavita_deleted and tonumber(ann.kavita_id)
            if dead_id then
                tombstoned[dead_id] = true
            elseif needsPush(ann) then
                pending[#pending + 1] = ann
            end
        end
        -- 墓碑单独一批也要能推（删除不需要 create/update）；两样都没有才算零请求。
        local delete_ids = {}
        for id in pairs(tombstoned) do delete_ids[#delete_ids + 1] = id end
        table.sort(delete_ids)
        if #pending == 0 and #delete_ids == 0 then
            -- 无可推：与「真推成功」区分开，核心才不会把 changed 谎报给首页。
            return cb(true, nil, { pushed = 0, adopted = 0, conflicts = 0, deleted = 0 })
        end

        -- 锚点先全部算好：有一条找不回段落就整批不发（空 xPath 会让一批失败项在远端挤成同键）。
        local plans = {}
        for _idx, ann in ipairs(pending) do
            local anchor = Position.anchor(ann.text, ann.pos0, path)
            if not anchor or not anchor.xPath or anchor.xPath == "" then
                return cb(nil, T(_("划线无法定位，本轮暂不推送：%1"), ann.text))
            end
            plans[#plans + 1] = { ann = ann, anchor = anchor }
        end

        job = ownerIdAsync(self, function(owner_id)
            if cancelled then return end
            -- 一批只对一次账：GET 失败宁可不推，也不盲建重复。
            job = Annotation.listByChapter(self.client, entry.chapterId, owner_id, function(list, lerr)
                if cancelled then return end
                if not list then return cb(nil, lerr) end
                local remote, by_id = {}, {}
                for _idx, item in ipairs(list) do
                    local id = tonumber(item.id)
                    if id and not tombstoned[id] then
                        remote[#remote + 1] = item
                        by_id[id] = item
                    end
                end

                --- 认领远端那条：回填 id / 坐标 / 原值，后续 update 才有原值可回传。
                --- **不碰 kavita_note 基线**：本地备注还是空的（远端文本要等 pull 才进 note），
                --- 这时候把远端备注记成基线，下一轮就会把「本地空」判成用户清空 → update 掉网页作者的内容。
                --- 基线只在真的写成功、或本地文本已经与远端相同时才补。
                ---@param ann table 本地条目（原地改写）
                ---@param hit table 远端 DTO
                local function adopt(ann, hit)
                    ann.kavita_id = tonumber(hit.id)
                    ann.kavita_xpath, ann.kavita_ending_xpath = hit.xPath, hit.endingXPath
                    ann.kavita_comment, ann.kavita_comment_html = hit.comment, hit.commentHtml
                    ann.kavita_slot, ann.kavita_spoiler = hit.selectedSlotIndex, hit.containsSpoiler
                end

                local pushed, adopted, conflicts, index = 0, 0, 0, 0
                local step

                --- 把本批墓碑从 payload 数组里摘掉：核心随后按这个数组回写快照，出列才算数。
                local function dropTombstones()
                    for i = #annotations, 1, -1 do
                        local ann = annotations[i]
                        local id = ann.kavita_deleted and tonumber(ann.kavita_id)
                        if id and tombstoned[id] then table.remove(annotations, i) end
                    end
                end

                --- 先写后删：全部 create / update 成功才发一次 bulk-delete（body = 裸 id 数组）。
                --- 200 ⇒ 墓碑出列；400 ⇒ 重拉一次该章确认真实状态后收尾（不无限重试）；
                --- 其余失败 ⇒ 整批 cb(nil)，快照留脏、墓碑保留，下轮重试。
                local function finishBatch()
                    if #delete_ids == 0 then
                        return cb(true, nil, { pushed = pushed, adopted = adopted,
                            conflicts = conflicts, deleted = 0 })
                    end
                    job = self.client:json("POST", "/api/Annotation/bulk-delete", nil, delete_ids,
                        function(_data, derr, code)
                            if cancelled then return end
                            if code and code >= 200 and code < 300 then
                                dropTombstones()
                                return cb(true, nil, { pushed = pushed, adopted = adopted,
                                    conflicts = conflicts, deleted = #delete_ids })
                            end
                            -- 400 是「id 不存在 / 不是你的 / 服务端拒绝」的同一分支：删除本身幂等，
                            -- 重拉一次按真实列表收尾，绝不循环重试。
                            if code ~= 400 then
                                return cb(nil, derr or _("Kavita 注解删除失败"))
                            end
                            job = Annotation.listByChapter(self.client, entry.chapterId, owner_id,
                                function(fresh, ferr)
                                    if cancelled then return end
                                    if not fresh then
                                        return cb(nil, ferr or _("Kavita 注解删除后复核失败"))
                                    end
                                    local alive = {}
                                    for _idx, item in ipairs(fresh) do
                                        alive[tonumber(item.id)] = true
                                    end
                                    local gone = 0
                                    for _idx, id in ipairs(delete_ids) do
                                        if alive[id] then
                                            logger.warn("kavita annotation delete rejected; drop tombstone", id)
                                        else
                                            gone = gone + 1
                                        end
                                    end
                                    dropTombstones()
                                    cb(true, nil, { pushed = pushed, adopted = adopted,
                                        conflicts = conflicts, deleted = gone })
                                end)
                        end)
                end

                --- 发一次 create / update；成功回填，失败整批收摊。
                ---@param ann table
                ---@param anchor table Position.anchor 的结果
                ---@param kind string "create" | "update"
                ---@param target table|nil update 的远端 DTO
                local function send(ann, anchor, kind, target)
                    local note = ann.note or ""
                    local wire = Annotation.toRemote(note)
                    local body = {
                        id = kind == "update" and tonumber(target.id) or nil,
                        chapterId = entry.chapterId, volumeId = entry.volumeId,
                        libraryId = entry.libraryId, seriesId = entry.seriesId,
                        ownerUserId = 0,
                        xPath = anchor.xPath, endingXPath = anchor.endingXPath,
                        selectedText = ann.text,
                        pageNumber = anchor.pageNumber or Position.spine(ann.pos0) or 0,
                        highlightCount = utf16Length(ann.text),
                        comment = wire.comment, commentHtml = wire.commentHtml,
                        -- 未改动的两个可写字段回传远端原值，否则一次 update 就把颜色 / 剧透清成默认。
                        selectedSlotIndex = tonumber(ann.kavita_slot) or 0,
                        containsSpoiler = ann.kavita_spoiler == true,
                    }
                    local api = kind == "create" and "/api/Annotation/create" or "/api/Annotation/update"
                    job = self.client:json("POST", api, nil, body, function(data, perr)
                        if cancelled then return end
                        local new_id = data and tonumber(data.id)
                        -- update 本来就带着 id：2xx 就认，回查也只可能命中同一条，不会重复建。
                        if not new_id and kind == "update" then new_id = tonumber(target.id) end
                        if new_id then
                            ann.kavita_id = new_id
                            ann.kavita_xpath, ann.kavita_ending_xpath = anchor.xPath, anchor.endingXPath
                            ann.kavita_note = note
                            pushed = pushed + 1
                            return step()
                        end
                        if not data then return cb(nil, perr) end
                        -- create 回了空体（反代吞掉 DTO）：只查**同一轮**对账列表（§8.3，一批一次 GET），
                        -- 命中才认成功；仍是 200 不算成功。本轮列表是创建前取的，通常查不到 → 留脏，
                        -- 下轮对账按 key 认领这条已建成的，不会重复建。
                        local hit = Annotation.match(remote, {
                            chapterId = entry.chapterId, xPath = anchor.xPath,
                            endingXPath = anchor.endingXPath, selectedText = ann.text,
                        })
                        if not hit then return cb(nil, _("Kavita 未确认注解已创建")) end
                        adopt(ann, hit)
                        ann.kavita_note = note
                        pushed = pushed + 1
                        step()
                    end)
                end

                --- 逐条判定：有 id 走冲突表与坐标守卫，无 id 先按键认领，认不到才新建。
                --- 跳过是纯本地判断，用循环推进，避免连续跳过时递归堆栈。
                step = function()
                    while true do
                        if cancelled then return end
                        index = index + 1
                        local plan = plans[index]
                        if not plan then
                            return finishBatch()
                        end
                        local ann, anchor = plan.ann, plan.anchor
                        local note = ann.note or ""
                        local id = tonumber(ann.kavita_id)
                        local current = id and by_id[id]
                        if id then
                            -- 有 id 但远端没了 = 网页端删了：不重建、不复活（拉取侧按 dropped 出列）。
                            if current then
                                -- 坐标守卫：update 改不了坐标，锚点漂了硬发会把备注写到旧位置。
                                local drifted = (ann.kavita_xpath and ann.kavita_xpath ~= ""
                                        and ann.kavita_xpath ~= anchor.xPath)
                                    or (ann.kavita_ending_xpath and ann.kavita_ending_xpath ~= ""
                                        and ann.kavita_ending_xpath ~= anchor.endingXPath)
                                if drifted then
                                    logger.warn("kavita annotation anchor drifted; skip update", id,
                                        ann.kavita_xpath, anchor.xPath)
                                else
                                    local base = ann.kavita_note
                                    local remote_note = Annotation.noteText(current.comment, current.commentHtml,
                                        current.commentPlainText)
                                    if base == nil then
                                        -- 没有基线（刚认领 / 老 payload）：本地有备注就是真实编辑，整条替换；
                                        -- 空则什么都不写，等 pull 把远端文本连同基线一起采纳。
                                        if Annotation.sameNote(note, remote_note) then
                                            if not Annotation.sameNote(note, "") then ann.kavita_note = note end
                                        elseif not Annotation.sameNote(note, "") then
                                            return send(ann, anchor, "update", current)
                                        end
                                    -- 没改备注就不写：远端怎么变都交给 pull 采纳。
                                    elseif not Annotation.sameNote(note, base) then
                                        if Annotation.sameNote(remote_note, base) then
                                            return send(ann, anchor, "update", current)
                                        elseif Annotation.sameNote(remote_note, note) then
                                            -- 两边改成了同一段：只补基线，不再白写一次。
                                            ann.kavita_note = note
                                        else
                                            -- 远端赢：本地改动留在 kavita_local_note 备查，下轮 pull 采纳远端文本。
                                            ann.kavita_local_note = note
                                            conflicts = conflicts + 1
                                            logger.warn("kavita annotation overridden by remote", id)
                                        end
                                    end
                                end
                            end
                        else
                            local hit = Annotation.match(remote, {
                                chapterId = entry.chapterId, xPath = anchor.xPath,
                                endingXPath = anchor.endingXPath, selectedText = ann.text,
                            })
                            if not hit then
                                return send(ann, anchor, "create")
                            end
                            adopt(ann, hit)
                            local remote_note = Annotation.noteText(hit.comment, hit.commentHtml,
                                hit.commentPlainText)
                            -- 首次认领：本地空 / 与远端相同 → 只采纳 id，不覆盖网页作者的备注。
                            -- 基线只在本地确实有这段文本时才补，否则下一轮会把「本地空」当成用户清空。
                            if not Annotation.sameNote(note, "") then
                                if Annotation.sameNote(note, remote_note) then
                                    ann.kavita_note = note
                                else
                                    return send(ann, anchor, "update", hit)
                                end
                            end
                            -- 只认领 id、没写远端：算 adopted（写了的只算 pushed）。
                            adopted = adopted + 1
                        end
                    end
                end
                step()
            end)
        end)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return { meta = meta, new = new, DEFAULT_HEARTBEAT_INTERVAL = DEFAULT_HEARTBEAT_INTERVAL }
