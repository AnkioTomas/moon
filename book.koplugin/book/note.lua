--[[--
阅读注解同步：notes 表快照经 Source 推送和拉取。

本地 notes 表是唯一的上传来源，避免异步回调发送已被修改的内存表。
阅读器侧的快照保存 / 应用在 ``reader.session.note``。

@module koplugin.book.book.note
--]]

local JSON = require("json")
local NoteDB = require("book.note_db")
local logger = require("utils.log")
local Normalize = require("book.note.normalize")

local Note = {}
local last_revision = 0

--- 生成单调递增的注解修订号（同一进程内不会重复）。
--- 取 os.time() 与上次值+1 的较大者：秒级时间戳在同一秒内多次写入会撞号，
--- 而修订号是 notes 表判定新旧的依据，必须严格递增。
---@return integer
function Note.nextRevision()
    last_revision = math.max(os.time(), last_revision + 1)
    return last_revision
end

--- 按源规则清洗注解，源没有自定义时走通用归一化。
---@param source BookSource|nil
---@param items table[]
---@param total_pages integer|nil
---@return table[]
function Note.clean(source, items, total_pages)
    if source and type(source.cleanAnnotations) == "function" then
        return source:cleanAnnotations(items, total_pages)
    end
    return Normalize.clean(items, total_pages)
end

--- 远端注解按 ``chapter_idx`` 分片落库；完整快照状态存于 payload 外层元数据。
---
--- 只覆盖远端确实报告了的分片：远端一条都没报时不写任何分片。协议字段缺失与
--- 「远端确实为空」在 wire 上无法区分，宁可漏掉云端删除，也不能把本地划线清空。
---@param source table
---@param stable_id string
---@param annotations table[]
---@param authoritative boolean|nil 远端明确返回完整快照时，缺失分片视为空
---@param done fun(ok: boolean)|nil
local function saveRemoteBuckets(source, stable_id, annotations, authoritative, done)
    local source_id = source.id
    local buckets = {}
    for _idx, item in ipairs(annotations or {}) do
        if type(item) == "table" then
            local idx = tonumber(item.chapter_idx)
            local key = idx and idx > 0 and idx or 0
            buckets[key] = buckets[key] or {}
            table.insert(buckets[key], item)
        end
    end
    if authoritative then
        for _idx, row in ipairs(NoteDB.all(source_id, stable_id)) do
            if row.sync_status == 1 then
                local key = tonumber(row.chapter_idx) or 0
                if buckets[key] == nil then buckets[key] = {} end
            end
        end
    end
    if not next(buckets) then
        if done then done(true) end
        return
    end
    local revision = Note.nextRevision()
    local ok = true
    for key, items in pairs(buckets) do
        local chapter_idx = key > 0 and key or nil
        local clean = Note.clean(source, items)
        local encoded, payload = pcall(JSON.encode, Normalize.pack(clean, authoritative))
        ok = encoded and NoteDB.upsertRemote(source_id, stable_id, chapter_idx, payload, revision)
        if not ok then
            logger.warn("book.note remote bucket failed", stable_id, chapter_idx, not encoded and payload or nil)
            break
        end
    end
    if done then done(ok) end
end

--- 上传成功后落定这一版快照：写回源侧回填过 id 的 payload 并标记已同步。
---
--- 读-比对-写在同一个同步调用中，保持原子性。
--- 上传期间用户又划了线（updated_at 变了）时整条跳过——既不覆盖新内容，也不清脏
--- 标记，下轮同步重新上传。
---@param row table notes 表行（含 source_id/stable_id/chapter_idx/updated_at）
---@param payload string|nil 源侧回填过远端 id 的快照
---@return boolean ok
---@return boolean|nil stale 上传期间本地又改过
local function confirm(row, payload)
    local live = NoteDB.get(row.source_id, row.stable_id, row.chapter_idx)
    if not live or live.updated_at ~= row.updated_at then
        return false, true
    end
    local ok = NoteDB.markSynced(row.source_id, row.stable_id, row.chapter_idx, row.updated_at, payload)
    if not ok then logger.warn("book.note confirm failed", row.stable_id) end
    return ok
end

--- 将一个 Source 的注解快照与远端收敛。本地脏快照先上传。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
local function runSyncAsync(source, opts, cb)
    opts = opts or {}
    local target = opts.identity and opts.identity.stable_id or "all"
    local can_pull = type(source.pullNotesAsync) == "function"
    local can_push = type(source.pushNotesAsync) == "function"
    local cancelled, current_job = false, nil
    local result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    logger.dbg("book.note sync start", source.id, target,
        opts.dirty_only and "dirty_only" or "full")
    --- 终结整次同步并回调；已取消时静默丢弃。
    ---@param value SyncResult|nil nil 表示失败
    local function finish(value, err)
        if cancelled then return end
        if value then
            logger.dbg("book.note sync done", source.id, target,
                "pulled", value.pulled or 0, "pushed", value.pushed or 0,
                "conflicts", value.conflicts or 0)
        else
            logger.warn("book.note sync failed", source.id, target, err)
        end
        if cb then cb(value, err) end
    end
    if not can_pull and not can_push then
        require("ui/uimanager"):nextTick(require("ui.guard").wrap("note sync", function()
            result.skipped, result.reason = true, "unsupported"
            finish(result)
        end))
        return { cancel = function() cancelled = true end }
    end

    local identities, seen = {}, {}
    --- 把一个待同步身份加入队列，按 (stable_id, chapter_idx) 去重。
    --- chapter_idx 为 0/nil 统一收敛成 nil（整本书那一份快照）。
    ---@param stable_id string|nil 空串与 nil 直接忽略
    ---@param chapter_idx integer|nil
    local function add(stable_id, chapter_idx)
        local key = tostring(stable_id) .. "\31" .. tostring(chapter_idx or 0)
        if stable_id and stable_id ~= "" and not seen[key] then
            seen[key] = true
            identities[#identities + 1] = {
                source_id = source.id, stable_id = stable_id,
                chapter_idx = chapter_idx and chapter_idx ~= 0 and chapter_idx or nil,
            }
        end
    end
    if opts.identity then
        add(opts.identity.stable_id, opts.identity.chapter_idx)
    elseif not opts.dirty_only then
        for _idx, stable_id in ipairs(require("book.books_db").libraryStableIdsBySource(source.id)) do
            add(stable_id)
        end
    end
    if not opts.identity then
        for _idx, row in ipairs(NoteDB.unsynced(source.id)) do
            add(row.stable_id, row.chapter_idx)
        end
    end

    local index = 1
    local book_pulled = {}
    --- 处理队列里的下一个身份：本地脏快照先推、再拉远端；队列空即 finish。
    --- 串行推进（每步在回调里递归），避免同时对同一本书发多个请求。
    local function nextIdentity()
        if cancelled then return end
        local identity = identities[index]
        index = index + 1
        if not identity then finish(result); return end

        --- 拉当前身份的远端注解并分片落库，然后推进到下一个身份。
        --- 同一本书只拉一次（远端按书返回全量），后续章节身份直接记账跳过。
        local function pullRemote()
            if opts.dirty_only or not can_pull then nextIdentity(); return end
            local stable_id = identity.stable_id
            if book_pulled[stable_id] then
                result.pulled = result.pulled + 1
                nextIdentity()
                return
            end
            current_job = source:pullNotesAsync(identity, function(annotations, err, meta)
                current_job = nil
                if cancelled then return end
                if type(annotations) ~= "table" then finish(nil, err or "notes pull failed"); return end
                book_pulled[stable_id] = true
                saveRemoteBuckets(source, stable_id, annotations,
                    type(meta) == "table" and meta.authoritative, function(ok)
                    if cancelled then return end
                    if not ok then finish(nil, "failed to save remote notes"); return end
                    result.pulled = result.pulled + 1
                    nextIdentity()
                end)
            end)
        end

        local row = NoteDB.get(source.id, identity.stable_id, identity.chapter_idx)
        if row and row.sync_status == 0 then
            if not can_push then
                result.conflicts = result.conflicts + 1
                pullRemote()
                return
            end
            local annotations = Normalize.decode(row.payload)
            if not annotations then
                finish(nil, "invalid local notes")
                return
            end
            current_job = source:pushNotesAsync(identity, annotations, function(value, err)
                current_job = nil
                if cancelled then return end
                if not value then
                    if opts.dirty_only then
                        result.push_error = err or "notes push failed"
                        logger.warn("book.note push failed; keep dirty", source.id, identity.stable_id, result.push_error)
                        nextIdentity()
                        return
                    end
                    result.conflicts = result.conflicts + 1
                    if can_pull then
                        pullRemote()
                    else
                        finish(nil, err or "notes push failed")
                    end
                    return
                end
                -- 源侧可在上传过程中原地回填远端标识，必须把回填后的快照落库，
                -- 否则下轮会重复上传。
                local clean = Note.clean(source, annotations)
                local ok_encode, pushed_payload = pcall(JSON.encode, clean)
                if not ok_encode then
                    finish(nil, "invalid local notes")
                    return
                end
                local confirmed, stale = confirm(row, pushed_payload)
                if stale then
                    -- 上传期间本地又改过：这次算推成功，但脏标记留着下轮再推
                    logger.dbg("book.note confirm skipped: local changed during push", row.stable_id)
                elseif not confirmed then
                    finish(nil, "notes confirm failed")
                    return
                end
                result.pushed = result.pushed + 1
                pullRemote()
            end)
            return
        end
        pullRemote()
    end
    require("ui/uimanager"):nextTick(require("ui.guard").wrap("note sync", nextIdentity))
    return { cancel = function()
            cancelled = true
            if current_job and current_job.cancel then current_job:cancel() end
        end }
end

local sync_queues = {}

--- 同一数据源的注解同步严格串行，避免两个快照同时创建同一条远端注解。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
function Note.syncAsync(source, opts, cb)
    local key = source.id
    local queue = sync_queues[key]
    if not queue then
        queue = { running = false, items = {} }
        sync_queues[key] = queue
    end
    local task = { source = source, opts = opts, cb = cb, cancelled = false }
    queue.items[#queue.items + 1] = task

    local function startNext()
        if queue.running then return end
        local next_task = table.remove(queue.items, 1)
        while next_task and next_task.cancelled do
            next_task = table.remove(queue.items, 1)
        end
        if not next_task then
            sync_queues[key] = nil
            return
        end
        queue.running = true
        next_task.job = runSyncAsync(next_task.source, next_task.opts, function(result, err)
            next_task.done = true
            queue.running = false
            if not next_task.cancelled and next_task.cb then next_task.cb(result, err) end
            startNext()
        end)
    end
    startNext()
    return { cancel = function()
            -- 已结束的任务不再碰队列：此时 queue 可能已换成新的、或正跑着别的任务。
            if task.done then return end
            task.cancelled = true
            if task.job and task.job.cancel then
                task.job:cancel()
                task.job = nil
                queue.running = false
                startNext()
            end
        end }
end

return Note
