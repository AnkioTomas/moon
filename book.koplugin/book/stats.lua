--[[--
阅读统计同步：reading_stats 经属主 Source 推送与拉取。

当前页计时采集在 ``reader.session.stats``。

reading_stats 是本地唯一事实来源：本地采集写成待同步记录，
远端拉取（capabilities.stats_pull）写成已同步记录；有云端日桶的日期展示以云端为准。
网络状态、同步时机、重试和 wire 协议由 Source 负责。

@module koplugin.book.book.stats
--]]

local StatsDB = require("book.stats_db")
local logger = require("utils.log")
local SourceCapabilities = require("source.base").SourceCapabilities
local Stats = {}
local PUSH_BATCH = 200

--- 在飞推送令牌，键为 source.id。读行到 markSynced 之间没有占位，
--- 关书推送与联网重推重叠会把同一批行各报一遍（微信时长直接翻倍）。
---@type table<string, table>
local pushing = {}

--- 把本地待同步统计交给 Source，成功后只确认对应本地记录。
--- 网络、节流、重试和上传时机全部由 Source 决定。
--- 默认按本次读取的行 id 标记 sync_status=1；Source 若在结果里带 ``synced_ids``
--- 则只确认这些行，其余保持待上传，等下一次重试——逐条上报的源部分失败时，
--- 已上报的段不会被重复计时，未上报的段也不会被误确认。不删除历史统计。
--- 同一源已有一批在飞时回 ``busy``，调用方按“本轮无可推”处理；在飞那一轮会循环推到空。
---@param source BookSource
---@param done fun(ok: boolean, result: any, confirmed: integer|nil)|nil result 为 Source 结果、empty、busy 或错误
---@return table|nil job 可取消任务；无待同步记录或已有在飞时为 nil
function Stats.push(source, done)
    if type(source.pushStatsAsync) ~= "function" then
        if done then done(false, "unsupported") end
        return
    end
    if pushing[source.id] then
        if done then done(true, "busy") end
        return
    end
    local rows = StatsDB.unsyncedBySource(source.id, PUSH_BATCH)
    if #rows == 0 then
        if done then done(true, "empty") end
        return
    end
    local ids = {}
    for _idx, row in ipairs(rows) do ids[#ids + 1] = row.id end
    local token = {}
    local function release()
        if pushing[source.id] == token then pushing[source.id] = nil end
    end

    --- 处理 Source 上传结果；远端确认后再确认本地版本。
    local function onResult(result, err)
        release()
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
    pushing[source.id] = token
    local job = source:pushStatsAsync(rows, onResult)
    return { cancel = function()
        release()
        if job and job.cancel then job:cancel() end
    end }
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
    for _idx, row in ipairs(raw) do
        if validRecord(row) then
            rows[#rows + 1] = row
        else
            skipped = skipped + 1
        end
    end
    return rows, type(result.rows) == "table" and result.replace or nil, skipped
end

--- 从 Source 拉取统计记录并落库。Source 返回领域记录，不返回 wire。
--- 拉取记录直接按已同步状态保存，不会在下一次 push 中重新上传；
--- 清理旧已同步行与写入本批记录在同一事务内完成，中途失败整体回滚。
---@param source BookSource
---@param done fun(ok: boolean, result: table|string|nil)|nil
---@return table|nil job Source 返回的可取消任务
function Stats.pull(source, done)
    if type(source.pullStatsAsync) ~= "function" then
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

--- 先上传本地未确认统计，再拉取远端聚合落库。
---@param source BookSource
---@param opts table|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
function Stats.syncAsync(source, opts, cb)
    opts = opts or {}
    local can_pull = SourceCapabilities.supportsStatsPull(source)
        and type(source.pullStatsAsync) == "function"
    local can_push = type(source.pushStatsAsync) == "function"
    local cancelled, current_job = false, nil
    local result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    local push_error
    --- 终结整次同步并回调；已取消时静默丢弃。
    ---@param value SyncResult|nil nil 表示失败
    local function finish(value, err)
        if cancelled then return end
        if value then
            local compacted = StatsDB.compactSynced(source.id, os.time() - 30 * 86400, 1000)
            if compacted == nil then
                logger.warn("book.stats compact failed", source.id)
            end
        end
        if cb then cb(value, err) end
    end
    if not can_pull and not can_push then
        require("ui/uimanager"):nextTick(function()
            result.skipped, result.reason = true, "unsupported"
            finish(result)
        end)
        return { cancel = function() cancelled = true end }
    end
    --- 拉取远端统计后终结同步；dirty_only 路径只推不拉。
    local function pull()
        if cancelled then return end
        if not can_pull or opts.dirty_only then finish(result); return end
        current_job = Stats.pull(source, function(ok, pulled)
            current_job = nil
            if cancelled then return end
            if not ok then
                local pull_error = pulled or "stats pull failed"
                if push_error then
                    pull_error = tostring(push_error) .. "; " .. tostring(pull_error)
                end
                finish(nil, pull_error)
                return
            end
            result.pulled = pulled.imported
            result.push_error = push_error
            finish(result)
        end)
    end
    --- 分批上传本地未确认统计，单批确认后再取下一批，内存占用与请求体有上限。
    local function push()
        if cancelled then return end
        if not can_push then pull(); return end
        current_job = Stats.push(source, function(ok, value, confirmed)
            current_job = nil
            if cancelled then return end
            if not ok then
                push_error = value or "stats push failed"
                logger.warn("book.stats push failed; continue pulling", source.id, push_error)
                pull()
                return
            end
            if value == "empty" or not confirmed or confirmed == 0 then
                pull()
                return
            end
            result.pushed = result.pushed + confirmed
            push()
        end)
    end
    require("ui/uimanager"):nextTick(push)
    return { cancel = function()
            cancelled = true
            if current_job and current_job.cancel then current_job:cancel() end
        end }
end

return Stats
