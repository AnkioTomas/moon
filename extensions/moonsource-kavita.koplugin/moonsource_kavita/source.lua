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
漫画：装了 kamare 插件且在线时交它在线看（开书回调 handled），否则下载 cbz 用内置阅读器。

@module moonsource_kavita.source
--]]

local Client = require("moonsource_kavita.client")
local Position = require("moonsource_kavita.position")
local Stats = require("moonsource_kavita.stats")
local SourceBase = require("source.base")
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

---@class KavitaSource : SourceBase
---@field client KavitaClient
---@field _heartbeat KavitaHeartbeat|nil 阅读期进度心跳；无则未在跑
local Source = setmetatable({}, { __index = SourceBase })
Source.__index = Source

---@return BookSourceMeta
local function meta()
    return { id = ID, name = _("Kavita"), type = "book" }
end

---@return KavitaSource
local function new()
    local self = setmetatable(meta(), Source) --[[@as KavitaSource]]
    self.client = Client.new(require("utils.settings").getSource(ID))
    return self
end

function Source:configured()
    return self.client:configured()
end

--- 能力：书架 + 统计拉取（推送是纯本地确认，见 pushStatsAsync），其余走基类默认（全 false）。
---@return SourceCapabilities
function Source:capabilities()
    local caps = SourceBase.capabilities(self)
    caps.stats_pull = true
    return caps
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
                -- 真实进度在卷行上；容器行的 series 级占位是多余的（旧版回填过就清掉）。
                if here and ProgressDB.dropRemote(source_id, stable_id) then
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
        -- 写入数随结果回给核心：纯书行物化也要让桌面知道「统计变了」（stats_changed）。
        result.materialized = materializeVolumes(result.identities, titles)
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

--- 打开一卷：漫画（cbz / 图片目录）在线且装了 kamare 就从 Kavita 记录的页交它在线看，
--- 回调 handled；kamare 打不开时 cbz 退回下载，图片目录报错。其余格式下载。
--- 关查看器时把页码记成远端版本地进度（kamare 已推给 Kavita），书架看得到进度。
---@param ref BookIdentity 承载这一卷的书库行
---@param entry table
---@param toc table[] 同 series 的卷，章末续读按 chapterId 找下一卷
---@param title string
---@param cb fun(path: string|nil, err: string|nil, meta: { handled: boolean }|nil)
---@return { cancel: fun() }
function Source:openEntry(ref, entry, toc, title, cb)
    local Kamare = require("moonsource_kavita.kamare")
    local cached = MAGIC[entry.format] and validFile(
        T("%1/%2.%3", require("utils.paths").bookWorkDir(ref.stable_id, self.id), entry.chapterId, entry.format),
        entry.format)
    if (entry.format ~= "cbz" and entry.format ~= "image") or cached or not online() or not Kamare.available() then
        return self:fetchVolume(ref, entry, cb)
    end
    local job, cancelled = nil, false
    local function show(item, start_page)
        return Kamare.open({
            base_url = self.client.base_url, api_key = self.client.api_key,
            entry = item, title = title, start_page = start_page,
            on_close = function(page, total)
                total = tonumber(total) or item.pages
                page = tonumber(page) or 1
                if total > 0 then
                    require("book.progress_db").upsertRemote(self.id, ref.stable_id, {
                        fraction = math.min(1, page / total), page = page, total_pages = total,
                        updated_at = os.time(),
                    })
                end
            end,
            on_next = function(next_id)
                for _idx, next_entry in ipairs(toc) do
                    if tostring(next_entry.chapterId) == tostring(next_id) then return show(next_entry, 1) end
                end
            end,
        })
    end
    job = self.client:json("GET", "/api/Reader/get-progress", { chapterId = entry.chapterId }, nil, function(remote)
        if cancelled then return end
        local read = remote and tonumber(remote.pageNum) or 0
        local viewer, err = show(entry, math.max(1, math.min(read + 1, entry.pages)))
        if viewer then return cb(nil, nil, { handled = true }) end
        if entry.format ~= "cbz" then return cb(nil, err) end
        job = self:fetchVolume(ref, entry, cb)
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

--- 多卷选卷：标注已下载 / 在读 / 已读；关窗没选算取消。
---@param series Book
---@param toc table[]
---@param cb fun(entry: table|nil)
local function pickVolume(series, toc, cb)
    local Paths = require("utils.paths")
    local items = {}
    for _idx, entry in ipairs(toc) do
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
        items[#items + 1] = { text = entry.title, value = entry, mandatory = state }
    end
    local chosen = false
    require("ui.themes.widgets.list"):new{
        title = series.title or _("选择卷"),
        items = items,
        on_select = function(entry)
            chosen = true
            cb(entry)
        end,
        -- 单选点按时先关窗、同一拍再 on_select：下一拍还没选中就是用户关掉了列表。
        close_callback = function()
            require("ui/uimanager"):nextTick(function()
                if not chosen then cb(nil) end
            end)
        end,
    }:show()
end

--- 打开：已下载的直接开（不联网）；单卷 series 下到 series 行，多卷选卷后下到卷行。
function Source:openBookAsync(identity, _opts, cb)
    local path = downloaded(self.id, identity.stable_id)
    if path then return SourceBase.defer(cb, path) end
    local job, cancelled = nil, false
    local function finish(file, err, meta)
        if not cancelled then cb(file, err, meta) end
    end
    local series_id, chapter_id = splitId(identity.stable_id)
    job = self:toc(series_id, function(toc, err)
        if not toc then return finish(nil, err) end
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

--- 注解快照保留 Kavita 注解 id 与已推送的备注：核心按 pos0 之外的字段一律丢弃。
---@param items table[]
---@param total_pages integer|nil
---@return table[]
function Source:cleanAnnotations(items, total_pages)
    local Normalize = require("book.note.normalize")
    local out = {}
    for _idx, item in ipairs(items) do
        local clean = Normalize.clean({ item }, total_pages)[1]
        if clean then
            clean.kavita_id, clean.kavita_note = item.kavita_id, item.kavita_note
            out[#out + 1] = clean
        end
    end
    return out
end

--- 阅读器里的注解不带 Kavita id：按 pos0 从上一版快照接过来，免得每次保存都重建远端注解。
---@param previous table[]
---@param current table[]
---@return table[]
function Source:prepareLocalAnnotations(previous, current)
    local by_pos = {}
    for _idx, old in ipairs(previous) do
        if old.kavita_id and old.pos0 then by_pos[old.pos0] = old end
    end
    for _idx, item in ipairs(current) do
        local old = item.pos0 and by_pos[item.pos0]
        if old and not item.kavita_id then
            item.kavita_id, item.kavita_note = old.kavita_id, old.kavita_note
        end
    end
    return current
end

--- Kavita 的 highlightCount 按 UTF-16 码元计。
---@param s string
---@return integer
local function utf16Length(s)
    local n = 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + (#ch == 4 and 2 or 1) end
    return n
end

--- 划线推到 Kavita：没 id 的新建、备注改过的更新，id 原地回填由核心落库。
--- Kavita 只认 epub 注解；删除不同步（远端删除接口未确认，宁可多留不误删）。
--- 有一条成功就算成功（回填的 id 要落库，否则重试会重复建），失败的那几条没 id，下次笔记变动再推；
--- 全部失败才报错，脏标记留着重试。
---@param identity BookIdentity
---@param annotations table[]
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Source:pushNotesAsync(identity, annotations, cb)
    local job, cancelled = nil, false
    job = self:entry(identity, function(entry, err)
        if cancelled then return end
        if not entry then return cb(nil, err) end
        if entry.format ~= "epub" then return cb(true) end
        local path = downloaded(self.id, identity.stable_id)
        local pending = {}
        for _idx, ann in ipairs(annotations) do
            if ann.drawer and type(ann.pos0) == "string" and type(ann.text) == "string"
                and (not ann.kavita_id or (ann.kavita_note or "") ~= (ann.note or "")) then
                pending[#pending + 1] = ann
            end
        end
        local index, pushed, failed = 0, 0, nil
        local function nextOne()
            index = index + 1
            local ann = pending[index]
            if not ann then
                if pushed == 0 and failed then return cb(nil, failed) end
                return cb(true)
            end
            local anchor = Position.anchor(ann.text, ann.pos0, path) or {}
            local body = {
                id = ann.kavita_id,
                chapterId = entry.chapterId, volumeId = entry.volumeId,
                libraryId = entry.libraryId, seriesId = entry.seriesId,
                ownerUserId = 0,
                xPath = anchor.xPath or "", endingXPath = anchor.endingXPath or "",
                selectedText = ann.text, comment = ann.note or "", commentHtml = "",
                selectedSlotIndex = 0, containsSpoiler = false,
                pageNumber = anchor.pageNumber or Position.spine(ann.pos0) or 0,
                highlightCount = utf16Length(ann.text),
            }
            local api = ann.kavita_id and "/api/Annotation/update" or "/api/Annotation/create"
            job = self.client:json("POST", api, nil, body, function(data, perr)
                if cancelled then return end
                if data then
                    ann.kavita_id = ann.kavita_id or data.id
                    ann.kavita_note = ann.note or ""
                    pushed = pushed + 1
                else
                    failed = failed or perr
                end
                nextOne()
            end)
        end
        nextOne()
    end)
    return { cancel = function()
        cancelled = true
        job:cancel()
    end }
end

return { meta = meta, new = new, DEFAULT_HEARTBEAT_INTERVAL = DEFAULT_HEARTBEAT_INTERVAL }
