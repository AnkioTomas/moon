--[[--
阅读统计：采集当前页停留时间，导入历史统计，并通过属主 Source 同步。

reading_stats 是本地唯一事实来源：本地采集和本地导入写成待同步记录，
远端拉取（capabilities.stats_pull）写成已同步记录；有云端日桶的日期展示以云端为准。
网络状态、同步时机、重试和 wire 协议由 Source 负责。

@module koplugin.book.book.stats
--]]

local StatsDB = require("db.stats")
local logger = require("utils.log")
local SourceCapabilities = require("types.book_source").SourceCapabilities
local Stats = {}

local PULL_TTL = 30 * 60

--- 当前阅读页的内存计时会话。
---@class ReadingStatsSession
---@field identity BookIdentity 当前文档身份
---@field page number 当前页码；0 表示未知
---@field total_pages number 当前文档总页数；未知时为 0
---@field chapter_idx integer|nil 当前章节序号（整本书为 nil）
---@field chapter_fraction number|nil 当前章节阅读比例（0..1）
---@field started_at integer 当前页开始计时的 Unix 时间戳

---@type ReadingStatsSession|nil
local session

--- 结清一个页面计时段并写入待同步统计。
--- 停留不足 1 秒时直接丢弃；数据库错误通过 done 返回。
---@param current ReadingStatsSession
---@param done fun(err: any|nil)|nil
---@return nil
local function settle(current, done)
    local duration = os.time() - current.started_at
    if duration < 1 or current.page < 1 then
        if done then done() end
        return
    end
    local row = {
        source_id = current.identity.source_id,
        stable_id = current.identity.stable_id,
        record_type = "page",
        page = current.page,
        start_time = current.started_at,
        duration = duration,
        total_pages = current.total_pages,
        chapter_idx = current.chapter_idx,
        chapter_fraction = current.chapter_fraction,
    }
    local ok = StatsDB.add(row)
    if not ok then
        logger.warn("book.stats write failed", row.stable_id)
    end
    if done then done(not ok and "failed to record reading stats" or nil) end
end

--- 移除当前内存会话，并在存在活动计时段时结清它。
--- 先清空 session，避免重复结算同一计时段。
---@param done fun(err: any|nil)|nil
---@return nil
local function stopSession(done)
    local current = session
    session = nil
    if current then
        settle(current, done)
    elseif done then
        done()
    end
end

--- 开始或恢复当前页计时。
--- 启动新会话前会先结清遗留会话，防止异常生命周期丢失统计。
---@param snapshot ReaderSessionSnapshot
---@return nil
function Stats.start(snapshot)
    stopSession()
    if not snapshot or not snapshot.identity then return end
    session = {
        identity = snapshot.identity,
        page = tonumber(snapshot.page) or 0,
        total_pages = tonumber(snapshot.total_pages) or 0,
        chapter_idx = snapshot.identity.chapter_idx,
        chapter_fraction = snapshot.chapter_fraction,
        started_at = os.time(),
    }
end

--- 翻页时结清旧页并开始新页计时。
--- 没有活动会话、页码非法或页码未变化时不执行任何操作。
---@param snapshot ReaderSessionSnapshot
---@return nil
function Stats.onPage(snapshot)
    local current = session
    if not snapshot then return end
    local page = tonumber(snapshot.page)
    if not current or not page or page == current.page then return end
    settle(current)
    current.page = page
    current.total_pages = tonumber(snapshot.total_pages) or 0
    current.chapter_fraction = snapshot.chapter_fraction
    current.started_at = os.time()
end

--- 停止计时；最后一段落库后调用 done。
---@param done fun(err: any|nil)|nil
---@return nil
function Stats.stop(done)
    stopSession(done)
end

--- 把本地待同步统计交给 Source，成功后只确认对应本地记录。
--- 网络、节流、重试和上传时机全部由 Source 决定。
--- 默认按本次读取的行 id 标记 sync_status=1；Source 若在结果里带 ``synced_ids``
--- 则只确认这些行，其余保持待上传，等下一次重试——逐条上报的源部分失败时，
--- 已上报的段不会被重复计时，未上报的段也不会被误确认。不删除历史统计。
---@param source BookSource
---@param done fun(ok: boolean, result: any, confirmed: integer|nil)|nil result 为 Source 结果、empty 或错误
---@return table|nil job Source 返回的可取消任务；无待同步记录时为 nil
function Stats.push(source, done)
    if not source or type(source.pushStatsAsync) ~= "function" then
        if done then done(false, "unsupported") end
        return
    end
    local rows = StatsDB.unsyncedBySource(source.id)
    if #rows == 0 then
        if done then done(true, "empty") end
        return
    end
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = row.id end

    --- 处理 Source 上传结果；远端确认后再确认本地版本。
    ---@param result any
    ---@param err any
    ---@return nil
    local function onResult(result, err)
        if not result then
            if done then done(false, err) end
            return
        end
        local confirm_ids = type(result) == "table" and type(result.synced_ids) == "table"
            and result.synced_ids or ids
        if #confirm_ids == 0 then
            if done then done(true, result, 0) end
            return
        end
        if StatsDB.markSynced(confirm_ids) then
            if done then done(true, result, #confirm_ids) end
        else
            logger.warn("book.stats confirm failed", #confirm_ids)
            if done then done(false, "failed to confirm reading stats") end
        end
    end
    return source:pushStatsAsync(rows, onResult)
end

--- 判断一条领域统计记录是否具备可持久化的最小字段。
--- page 和 total_pages 可缺省为 0；身份、开始时间和正数时长必须存在。
---@param row table|nil
---@return boolean
local function validRecord(row)
    return type(row) == "table"
        and type(row.source_id) == "string" and row.source_id ~= ""
        and type(row.stable_id) == "string" and row.stable_id ~= ""
        and tonumber(row.start_time) and tonumber(row.duration) and tonumber(row.duration) > 0
        or false
end

--- 解析 pullStatsAsync 回包：数组=追加去重；``{ rows, replace }``=云端覆盖入库。
--- 同时滤掉字段不全的行，让入库循环可以对失败直接 assert。
---@param result BookStatsRow[]|BookStatsPullResult|nil
---@return BookStatsRow[]|nil, BookStatsPullReplace|nil, integer skipped
local function normalizePullResult(result)
    if type(result) ~= "table" then
        return nil, nil, 0
    end
    local raw = type(result.rows) == "table" and result.rows or result
    local rows, skipped = {}, 0
    for _, row in ipairs(raw) do
        if validRecord(row) then
            rows[#rows + 1] = row
        else
            skipped = skipped + 1
        end
    end
    return rows, type(result.rows) == "table" and result.replace or nil, skipped
end

--- 是否距上次成功 pull 已超过节流窗口。
---@param source BookSource
---@return boolean
function Stats.shouldPull(source)
    if not SourceCapabilities.supportsStatsPull(source) then
        return false
    end
    if not source.configured or not source:configured() then
        return false
    end
    local cfg = require("utils.settings").getSource(source.id)
    local last = tonumber(cfg and cfg.last_stats_pull_at) or 0
    return os.time() - last >= PULL_TTL
end

--- 记录成功 pull 时间戳（节流用）。
---@param source BookSource
---@return nil
local function markPulled(source)
    if not source or type(source.id) ~= "string" or source.id == "" then
        return
    end
    -- saveSource 是整表覆盖：必须读回完整配置再改，否则连 token 一起抹掉
    local Settings = require("utils.settings")
    local cfg = Settings.getSource(source.id)
    cfg.last_stats_pull_at = os.time()
    Settings.saveSource(source.id, cfg)
end

--- 将本地导入的统计记录逐条写入 reading_stats，保持待上传状态。
--- 每个 tick 写一条，避免大批量导入长时间阻塞 UI；已存在的记录跳过。
---@param rows table[]|nil
---@param done fun(result: { imported: integer, skipped: integer, failed: integer })|nil
---@return nil
local function importRows(rows, done)
    local UIManager = require("ui/uimanager")
    local result = { imported = 0, skipped = 0, failed = 0 }
    local pending = {}
    for _, row in ipairs(rows or {}) do
        if validRecord(row) then
            pending[#pending + 1] = row
        else
            result.skipped = result.skipped + 1
        end
    end
    local pos = 1

    --- 每个 tick 写入一条记录，避免大批量导入长时间阻塞 UI。
    ---@return nil
    local function nextItem()
        local row = pending[pos]
        pos = pos + 1
        if not row then
            if done then done(result) end
            return
        end
        if StatsDB.exists(row) then
            result.skipped = result.skipped + 1
        elseif StatsDB.add(row) then
            result.imported = result.imported + 1
        else
            result.failed = result.failed + 1
            logger.warn("book.stats import failed", row.stable_id)
        end
        UIManager:nextTick(nextItem)
    end
    UIManager:nextTick(nextItem)
end

--- 从 Source 拉取统计记录并落库。Source 返回领域记录，不返回 wire。
--- 拉取记录直接按已同步状态保存，不会在下一次 push 中重新上传；
--- 清理旧已同步行与写入本批记录在同一事务内完成，中途失败整体回滚。
---@param source BookSource
---@param done fun(ok: boolean, result: table|string|nil)|nil
---@return table|nil job Source 返回的可取消任务
function Stats.pull(source, done)
    if not source or type(source.pullStatsAsync) ~= "function" then
        if done then done(false, "unsupported") end
        return
    end
    return source:pullStatsAsync(function(result, err)
        local rows, replace, invalid = normalizePullResult(result)
        if not rows then
            if done then done(false, err) end
            return
        end
        local saved = StatsDB.replaceSynced(source.id, replace, rows)
        if saved then
            saved.skipped = saved.skipped + invalid
            saved.failed = 0
            if done then done(true, saved) end
        else
            if done then done(false, "failed to save pulled reading stats") end
        end
    end)
end

--- 后台拉取远端统计；仅 ``capabilities.stats_pull`` 源参与，默认 30 分钟节流。
---@param source BookSource
---@param opts { force?: boolean, on_done?: fun(ok: boolean, result: table|string|nil) }|nil
---@return nil
function Stats.pullInBackground(source, opts)
    opts = opts or {}
    if not SourceCapabilities.supportsStatsPull(source) then
        return
    end
    if not source.configured or not source:configured() then
        return
    end
    if not opts.force and not Stats.shouldPull(source) then
        return
    end
    if source._stats_pulling then
        return
    end
    source._stats_pulling = true
    Stats.pull(source, function(ok, result)
        source._stats_pulling = false
        if ok then
            markPulled(source)
        end
        if opts.on_done then
            opts.on_done(ok, result)
        end
    end)
end

--- 拉取并集合并，再上传本地未确认统计。
---@param source BookSource
---@param _opts table|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
function Stats.syncAsync(source, _opts, cb)
    local opts = _opts or {}
    local can_pull = source and SourceCapabilities.supportsStatsPull(source)
        and type(source.pullStatsAsync) == "function"
    local can_push = source and type(source.pushStatsAsync) == "function"
    local cancelled, current_job = false, nil
    local result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    --- 终结整次同步并回调；已取消时静默丢弃。
    ---@param value SyncResult|nil nil 表示失败
    ---@param err any
    local function finish(value, err)
        if not cancelled and cb then cb(value, err) end
    end
    if not can_pull and not can_push then
        require("ui/uimanager"):nextTick(function()
            result.skipped, result.reason = true, "unsupported"
            finish(result)
        end)
        return { cancel = function() cancelled = true end }
    end
    --- 上传本地未确认的统计行，然后终结同步。
    --- 无待传行或源不支持推送时直接按成功收尾；result.pushed 取源确认条数，
    --- 源没回报确认数时退回本次待传条数。
    local function push()
        if cancelled then return end
        if not can_push then finish(result); return end
        local pending = #StatsDB.unsyncedBySource(source.id)
        if pending == 0 then finish(result); return end
        current_job = Stats.push(source, function(ok, value, confirmed)
            current_job = nil
            if not ok then finish(nil, value); return end
            result.pushed = confirmed or pending
            finish(result)
        end)
    end
    if can_pull and not opts.dirty_only then
        current_job = Stats.pull(source, function(ok, pulled)
            current_job = nil
            if cancelled then return end
            if not ok then finish(nil, pulled or "stats pull failed"); return end
            result.pulled = pulled.imported
            push()
        end)
    else
        require("ui/uimanager"):nextTick(push)
    end
    return {
        cancel = function()
            cancelled = true
            if current_job and current_job.cancel then current_job:cancel() end
        end,
    }
end

--- 收集已登记书籍和章节的物理路径，供 DocSettings Lua 统计导入。
--- 同一路径只保留第一次出现的身份，避免重复读取同一个 sidecar。
---@return table[] candidates 含 path、source_id、stable_id，章节可含 chapter_idx
local function localStatCandidates()
    local BookDB = require("db.book")
    local ChapterDB = require("db.chapter")
    local out, seen = {}, {}

    --- 添加一个未出现过的有效物理路径。
    ---@param row table|nil
    ---@return nil
    local function add(row)
        if type(row) == "table" and type(row.path) == "string" and row.path ~= "" and not seen[row.path] then
            seen[row.path] = true
            out[#out + 1] = row
        end
    end
    for _, row in ipairs(BookDB.pathsAll()) do add(row) end
    for _, row in ipairs(ChapterDB.all()) do add(row) end
    return out
end

--- 读取 KOReader statistics 插件的 statistics.sqlite3。
--- 只读 page_stat_data，不修改外部数据库；书籍通过 partial md5 映射到
--- 本插件 local 源身份。文件、SQLite 模块或表不可用时返回空列表。
---@return table[] rows 可导入的领域统计记录
local function readKoreaderStatsDb()
    local rows = {}
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage or not DataStorage.getSettingsDir then return rows end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lfs_ok and lfs.attributes(path, "mode") ~= "file" then return rows end
    local sq_ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not sq_ok or not SQ3 then return rows end
    local conn = SQ3.open(path)
    if not conn then return rows end
    local BookDB = require("db.book")
    local stmt
    local query_ok = pcall(function()
        stmt = conn:prepare([[SELECT b.md5, p.page, p.start_time, p.duration, p.total_pages
            FROM page_stat_data p JOIN book b ON b.id=p.id_book
            WHERE p.duration > 0 ORDER BY p.start_time ASC;]])
        for item in stmt:rows() do
            local book = BookDB.getByMd5("local", item[1])
            if book then
                rows[#rows + 1] = {
                    source_id = book.source_id,
                    stable_id = book.stable_id,
                    record_type = "page",
                    page = tonumber(item[2]) or 0,
                    start_time = tonumber(item[3]) or 0,
                    duration = tonumber(item[4]) or 0,
                    total_pages = tonumber(item[5]) or 0,
                }
            end
        end
    end)
    if stmt then pcall(function() stmt:close() end) end
    pcall(function() conn:close() end)
    if not query_ok then return {} end
    return rows
end

--- 导入 KOReader statistics 插件的本地历史数据。
--- 先导入 statistics.sqlite3，再遍历已登记路径读取 DocSettings Lua 的 stats。
--- 旧 Lua 只有时间点和总时长，没有逐段时长，因此按时间点数量平均分配总时长；
--- 所有本地导入记录均保持 sync_status=0，等待所属 Source 上传。
---@param done fun(result: { imported: integer, skipped: integer, failed: integer })|nil
---@return { cancel: fun() } job 取消后停止后续分片且不调用 done
function Stats.importLocalAsync(done)
    local DocSettings = require("docsettings")
    local UIManager = require("ui/uimanager")
    local candidates = localStatCandidates()
    local external_rows = readKoreaderStatsDb()
    local result, index, cancelled = { imported = 0, skipped = 0, failed = 0 }, 1, false

    --- 分片导入外部 SQLite 和下一个 DocSettings 快照。
    ---@return nil
    local function nextItem()
        if cancelled then return end
        if #external_rows > 0 then
            local rows = external_rows
            external_rows = {}
            importRows(rows, function(imported)
                result.imported = result.imported + imported.imported
                result.skipped = result.skipped + imported.skipped
                result.failed = result.failed + imported.failed
                UIManager:nextTick(nextItem)
            end)
            return
        end
        local candidate = candidates[index]
        index = index + 1
        if not candidate then
            if done then done(result) end
            return
        end
        local ok, settings = pcall(DocSettings.open, DocSettings, candidate.path)
        local stats = ok and settings and settings:readSetting("stats") or nil
        local points = stats and stats.performance_in_pages
        if type(points) ~= "table" then
            result.skipped = result.skipped + 1
            UIManager:nextTick(nextItem)
            return
        end
        local times = {}
        for timestamp in pairs(points) do
            if tonumber(timestamp) then times[#times + 1] = tonumber(timestamp) end
        end
        table.sort(times)
        if #times == 0 then
            result.skipped = result.skipped + 1
            UIManager:nextTick(nextItem)
            return
        end
        local average = math.max(1, math.floor((tonumber(stats.total_time_in_sec) or 0) / #times + 0.5))
        local rows = {}
        for _, timestamp in ipairs(times) do
            rows[#rows + 1] = {
                source_id = candidate.source_id,
                stable_id = candidate.stable_id,
                record_type = "page",
                page = tonumber(points[timestamp]) or tonumber(points[tostring(timestamp)]) or 0,
                start_time = timestamp,
                duration = average,
                total_pages = tonumber(stats.pages) or 0,
            }
        end
        importRows(rows, function(imported)
            result.imported = result.imported + imported.imported
            result.skipped = result.skipped + imported.skipped
            result.failed = result.failed + imported.failed
            UIManager:nextTick(nextItem)
        end)
    end
    UIManager:nextTick(nextItem)
    return { cancel = function() cancelled = true end }
end

return Stats
