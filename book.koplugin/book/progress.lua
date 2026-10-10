--[[--
阅读进度数据：ProgressPosition 形态、钳制、修订号与 pending_progress 上行同步。
阅读器侧的采样、开书拉取与冲突处理在 ``reader.session.progress``。

@module koplugin.book.book.progress
--]]

--- 统一阅读位置（拉/推进度唯一形态）。
---@class ProgressPosition
---@field fraction number 全书比例 0..1，必填
---@field chapter_idx integer|nil 连续章序号（1-based）；部分源没有
---@field chapter_title string|nil 当前章节标题（跨源可读，不依赖 idx）
---@field chapter_fraction number|nil 章内比例 0..1
---@field page integer|nil 当前文档页码（1-based）
---@field total_pages integer|nil 当前文档总页数
---@field locator string|nil XPointer/CFI 等精确定位
---@field extra table|nil 源私有定位字段，原样往返本地库；跨源代码不得解读其内容
---@field updated_at integer|nil 进度/阅读最后活跃时间（含远端 readUpdateTime）

local logger = require("utils.log")
local ProgressDB = require("book.progress_db")

local Progress = {
    last_revision = 0,
    sync_runs = {},
}

--- fraction 钳制到 0..1。
---@return number
function Progress.clampFraction(raw)
    local n = tonumber(raw)
    if not n then
        return 0
    end
    if n > 1 and n <= 100 then
        n = n / 100
    end
    if n < 0 then
        return 0
    end
    if n > 1 then
        return 1
    end
    return n
end

--- 百分比钳制到 0..100 整数。
--- as_frac 或 (0,1) 区间值按比例换算；finished 为真且未满则抬到 100。
---@param raw any 原始进度（百分数或 0..1 比例）
---@param finished boolean|nil 是否已读完
---@param as_frac boolean|nil 强制按 0..1 比例解释
---@return number
function Progress.clampPercent(raw, finished, as_frac)
    local n = tonumber(raw) or 0
    if as_frac or (n > 0 and n < 1) then
        n = n * 100
    end
    n = math.floor(n + 0.5)
    if n < 0 then
        n = 0
    elseif n > 100 then
        n = 100
    end
    if finished and n < 100 then
        return 100
    end
    return n
end

--- 生成单调递增的进度修订号（同一进程内不会重复）。
--- 秒级时间戳在同一秒内多次写入会撞号，而修订号是 pending_progress 判定新旧的
--- 依据，必须严格递增。
---@return integer
function Progress.nextRevision()
    Progress.last_revision = math.max(os.time(), Progress.last_revision + 1)
    return Progress.last_revision
end

--- 只取通用阅读坐标的拷贝（剥掉 sync_status / updated_at 等库字段）。
---@param row ProgressPosition
---@return ProgressPosition
function Progress.rowPosition(row)
    return {
        fraction = row.fraction,
        chapter_idx = row.chapter_idx,
        chapter_title = row.chapter_title,
        chapter_fraction = row.chapter_fraction,
        page = row.page,
        total_pages = row.total_pages,
        locator = row.locator,
        extra = row.extra,
    }
end

--- 将一个 Source 的本地脏进度推到远端。Pull 只走 reader.session.progress.pull（开书冲突 UI）。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
local function syncOnce(source, opts, cb)
    opts = opts or {}
    local target = opts.identity and opts.identity.stable_id or "all"
    local can_push = type(source.putProgressAsync) == "function"
    local cancelled, current_job = false, nil
    local result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    logger.dbg("book.progress sync start", source.id, target,
        opts.dirty_only and "dirty_only" or "full")
    --- 终结整次同步并回调；已取消时静默丢弃。
    ---@param value SyncResult|nil nil 表示失败
    local function finish(value, err)
        if cancelled then return end
        if value then
            logger.dbg("book.progress sync done", source.id, target,
                "pulled", value.pulled or 0, "pushed", value.pushed or 0,
                "conflicts", value.conflicts or 0)
        else
            logger.warn("book.progress sync failed", source.id, target, err)
        end
        if cb then cb(value, err) end
    end
    if not can_push then
        require("ui/uimanager"):nextTick(function()
            result.skipped, result.reason = true, "unsupported"
            finish(result)
        end)
        return { cancel = function() cancelled = true end }
    end

    local identities, seen = {}, {}
    --- 把一个待同步身份加入队列，按 (stable_id, chapter_idx) 去重。
    ---@param source_id string
    ---@param stable_id string|nil 空串与 nil 直接忽略
    ---@param chapter_idx integer|nil nil 表示整本书
    local function add(source_id, stable_id, chapter_idx)
        local key = tostring(stable_id) .. "\31" .. tostring(chapter_idx or 0)
        if stable_id and stable_id ~= "" and not seen[key] then
            seen[key] = true
            identities[#identities + 1] = {
                source_id = source_id, stable_id = stable_id, chapter_idx = chapter_idx,
            }
        end
    end
    -- 只推不拉：全量与 dirty_only 的推送集合相同（本地脏行），区别只在推送失败是否中止
    if opts.identity then
        add(source.id, opts.identity.stable_id, opts.identity.chapter_idx)
    else
        for _idx, row in ipairs(ProgressDB.unsynced(source.id)) do
            add(source.id, row.stable_id, row.chapter_idx)
        end
    end

    local index = 1
    --- 处理队列里的下一个身份：本地脏行先推；队列空即 finish。从不 pull。
    local function nextIdentity()
        if cancelled then return end
        local identity = identities[index]
        index = index + 1
        if not identity then finish(result); return end

        local row = ProgressDB.get(source.id, identity.stable_id)
        if row and row.sync_status == 0 then
            current_job = source:putProgressAsync(identity, Progress.rowPosition(row), function(ok, err)
                current_job = nil
                if cancelled then return end
                if ok ~= true then
                    if opts.dirty_only then
                        result.push_error = err or "progress push failed"
                        logger.warn("book.progress push failed; keep dirty", source.id, identity.stable_id, result.push_error)
                        nextIdentity()
                        return
                    end
                    finish(nil, err or "progress push failed")
                    return
                end
                -- 按推送时的修订号确认：推送期间写入的新版本保持脏
                if not ProgressDB.markSynced(source.id, identity.stable_id, row.updated_at) then
                    logger.warn("book.progress confirm failed", identity.stable_id)
                    finish(nil, "progress confirm failed")
                    return
                end
                result.pushed = result.pushed + 1
                nextIdentity()
            end)
            return
        end
        nextIdentity()
    end
    require("ui/uimanager"):nextTick(nextIdentity)
    return { cancel = function()
            cancelled = true
            if current_job and current_job.cancel then current_job:cancel() end
        end }
end

--- 合并完全相同的重入同步；不同书籍/模式仍各自执行，不能混用结果。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
function Progress.syncAsync(source, opts, cb)
    opts = opts or {}
    local identity = opts.identity
    local key = table.concat({
        source.id,
        tostring(identity and identity.stable_id or "all"),
        tostring(identity and identity.chapter_idx or 0),
        opts.dirty_only and "dirty" or "full",
    }, "\31")
    local subscriber = { active = true, cb = cb }
    local run = Progress.sync_runs[key]
    if run then
        run.subscribers[#run.subscribers + 1] = subscriber
    else
        run = { subscribers = { subscriber } }
        Progress.sync_runs[key] = run
        run.job = syncOnce(source, opts, function(result, err)
            if Progress.sync_runs[key] == run then Progress.sync_runs[key] = nil end
            for _idx, item in ipairs(run.subscribers) do
                if item.active and item.cb then item.cb(result, err) end
            end
        end)
    end
    return { cancel = function()
            if not subscriber.active then return end
            subscriber.active = false
            for _idx, item in ipairs(run.subscribers) do
                if item.active then return end
            end
            if Progress.sync_runs[key] == run then
                Progress.sync_runs[key] = nil
                if run.job and run.job.cancel then run.job.cancel() end
            end
        end }
end

return Progress
