--[[--
阅读注解同步：notes 表快照经 Source 推送和拉取。

本地 notes 表是唯一的上传来源，避免异步回调发送已被修改的内存表。
阅读器侧的快照保存 / 应用在 ``reader.session.note``。

chapter_idx 0 是整本桶，正整数是章分片；payload 是 KOReader 注解完整快照，不是增量。
merge：远端空列表与字段缺失无法区分，宁可漏掉云端删除也不清本地划线；只有 authoritative 快照才把缺失分片视为空。
分页文档（PDF 等）的划线按页码与坐标内容去重，不比表地址。编排层对笔记域永远 dirty_only。

@module koplugin.book.book.note
--]]

local JSON = require("json")
local NoteDB = require("book.note_db")
local logger = require("utils.log")
local Normalize = require("book.note.normalize")
local Text = require("utils.text")

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
    local cleaned
    if source and type(source.cleanAnnotations) == "function" then
        cleaned = source:cleanAnnotations(items, total_pages)
    else
        cleaned = Normalize.clean(items, total_pages)
    end
    -- 源自己的清洗也可能漏掉历史重复；落库前再折叠一次，避免脏快照被原样写回。
    return (Normalize.unique(cleaned))
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
    local revision
    local ok = true
    for key, items in pairs(buckets) do
        local chapter_idx = key > 0 and key or nil
        local clean = Note.clean(source, items)
        local encoded, payload = pcall(JSON.encode, Normalize.pack(clean, authoritative))
        -- 幂等：内容与库里那行逐字节相同就不再写。否则每次开书都刷新 updated_at，
        -- 「什么都没变」会被编排层当成有新内容（重复 pull 必须不留痕）。
        local existing = encoded and NoteDB.get(source_id, stable_id, chapter_idx) or nil
        if not (encoded and existing and existing.payload == payload) then
            revision = revision or Note.nextRevision()
            ok = encoded and NoteDB.upsertRemote(source_id, stable_id, chapter_idx, payload, revision)
        end
        if not ok then
            logger.warn("book.note remote bucket failed", stable_id, chapter_idx, not encoded and payload or nil)
            break
        end
    end
    if done then done(ok) end
end

--- 用上传时那一版带来的远端 id 覆盖 live 快照里的同一条（按 pos0，退到 (text, chapter_idx)）。
--- 只搬 kavita_id / kavita_note：live 里的备注文本是用户刚改的，绝不能被上传时那份盖回去。
---@param live_items table[] 当前库里的条目（原地改写）
---@param pushed_items table[] 上传时那一版（源已回填 id）
---@return integer patched 真正盖上的条数
local function mergeBackfill(live_items, pushed_items)
    local by_pos, by_text = {}, {}
    for _idx, item in ipairs(pushed_items) do
        if item.kavita_id then
            if item.pos0 then by_pos[item.pos0] = item end
            local text_key = tostring(item.text or "") .. "\31" .. tostring(item.chapter_idx or 0)
            by_text[text_key] = item
        end
    end
    local patched = 0
    for _idx, item in ipairs(live_items) do
        local source_item = (item.pos0 and by_pos[item.pos0])
            or by_text[tostring(item.text or "") .. "\31" .. tostring(item.chapter_idx or 0)]
        if source_item and tostring(item.kavita_id) ~= tostring(source_item.kavita_id) then
            item.kavita_id, item.kavita_note = source_item.kavita_id, source_item.kavita_note
            patched = patched + 1
        end
    end
    return patched
end

--- 上传成功后落定这一版快照：写回源侧回填过 id 的 payload 并标记已同步。
---
--- 读-比对-写在同一个同步调用中，保持原子性。
--- 上传期间用户又划了线（updated_at 变了）时不清脏标记，但把这轮回填的远端 id 并进 live payload：
--- 整份丢弃会让下轮重新认领（甚至重复建），而覆盖回去会把新划的线抹掉。
---@param row table notes 表行（含 source_id/stable_id/chapter_idx/updated_at）
---@param payload string|nil 源侧回填过远端 id 的快照
---@return boolean ok
---@return boolean|nil stale 上传期间本地又改过
local function confirm(row, payload)
    local live = NoteDB.get(row.source_id, row.stable_id, row.chapter_idx)
    if not live then
        return false, true
    end
    if live.updated_at ~= row.updated_at then
        if payload ~= nil then
            local live_items, authoritative = Normalize.decode(live.payload)
            local pushed_items = Normalize.decode(payload)
            if live_items and pushed_items and mergeBackfill(live_items, pushed_items) > 0 then
                local ok_encode, merged = pcall(JSON.encode, Normalize.pack(live_items, authoritative))
                -- 合并失败也不阻塞：id 丢了由下轮对账按内容键认领，脏标记反正还留着。
                if not ok_encode
                    or not NoteDB.updatePayload(row.source_id, row.stable_id, row.chapter_idx, merged) then
                    logger.warn("book.note backfill merge failed", row.stable_id)
                end
            end
        end
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
    local current = require("source.auth").currentAccount(source.id)
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
        if not current() then finish(nil, "source account changed"); return end
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
                if not current() then finish(nil, "source account changed"); return end
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
            if row.account_pending == 1 then
                local book = require("book.books_db").shelfBook(source, identity.stable_id)
                if book and book.deleted == 1 and book.sync_status == 1 then
                    logger.dbg("book.note transfer kept locally: not on new shelf", source.id, identity.stable_id)
                    if not NoteDB.markSynced(source.id, identity.stable_id, identity.chapter_idx, row.updated_at) then
                        finish(nil, "failed to retain local notes")
                        return
                    end
                    return nextIdentity()
                end
            end
            local function push()
                current_job = source:pushNotesAsync(identity, annotations, function(value, err, data)
                    current_job = nil
                    if cancelled then return end
                    if not current() then finish(nil, "source account changed"); return end
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
                    -- 源如实回报这轮推了几条（对账后无可推是 0）；老源没有 data，按「推了一条」记。
                    result.pushed = result.pushed + (type(data) == "table" and tonumber(data.pushed) or 1)
                    if type(data) == "table" and tonumber(data.conflicts) then
                        result.conflicts = result.conflicts + tonumber(data.conflicts)
                    end
                    pullRemote()
                end)
            end
            -- 换号不是删除：整本覆盖接口先合入新账号快照；自带逐条对账的源自行处理。
            if (row.account_pending or 0) > 0 and can_pull
                and type(source.resetAccountAnnotations) ~= "function" then
                current_job = source:pullNotesAsync(identity, function(remote, err)
                    current_job = nil
                    if cancelled then return end
                    if not current() then finish(nil, "source account changed"); return end
                    if not remote then finish(nil, err or "notes pull failed"); return end
                    local paging = type(annotations[1] and annotations[1].page) == "number"
                    local merged = Normalize.merge(remote, annotations, paging)
                    if #merged < #annotations then finish(nil, "invalid local notes"); return end
                    annotations = merged
                    push()
                end)
            else
                push()
            end
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

---@class NoteSyncTask
---@field source BookSource
---@field opts table|nil
---@field cb function|nil
---@field cancelled boolean
---@field current fun(): boolean
---@field job { cancel: fun() }|nil
---@field done boolean|nil

---@class NoteSyncQueue
---@field items NoteSyncTask[]
---@field running NoteSyncTask|nil

---@type table<string, NoteSyncQueue>
local sync_queues = {}

---@param source_id string
function Note.abortSource(source_id)
    local queue = sync_queues[source_id]
    if not queue then return end
    sync_queues[source_id] = nil
    for _idx, task in ipairs(queue.items) do task.cancelled = true end
    local running = queue.running
    if running then
        running.cancelled = true
        if running.job then running.job:cancel() end
    end
end

--- 同一数据源的注解同步严格串行，避免两个快照同时创建同一条远端注解。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
function Note.syncAsync(source, opts, cb)
    local key = source.id
    local queue = sync_queues[key]
    if not queue then
        queue = { items = {} }
        sync_queues[key] = queue
    end
    local task = { source = source, opts = opts, cb = cb, cancelled = false,
        current = require("source.auth").currentAccount(source.id) }
    queue.items[#queue.items + 1] = task

    local function startNext()
        if queue.running then return end
        local next_task = table.remove(queue.items, 1)
        while next_task and (next_task.cancelled or not next_task.current()) do
            next_task = table.remove(queue.items, 1)
        end
        if not next_task then
            if sync_queues[key] == queue then sync_queues[key] = nil end
            return
        end
        queue.running = next_task
        next_task.job = runSyncAsync(next_task.source, next_task.opts, function(result, err)
            next_task.done = true
            queue.running = nil
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
                queue.running = nil
                startNext()
            end
        end }
end


--- 分页文档的 pos 是 {x,y,page} 表，tostring 只得到地址，不能当键。
---@param pos any
---@return string
local function posKey(pos)
    if type(pos) == "table" then
        return tostring(pos.page) .. "," .. tostring(pos.x) .. "," .. tostring(pos.y)
    end
    return tostring(pos or "")
end

--- 一条注解在所属快照内的身份：优先源侧 id，否则用内容坐标。
---@param item table
---@return string
local function itemId(item)
    if item.wr_bookmark_id then
        return "wr:" .. tostring(item.wr_bookmark_id)
    end
    if item.kavita_id then
        return "kv:" .. tostring(item.kavita_id)
    end
    local id = item.id or item.annotation_id
    if id ~= nil then
        return "id:" .. tostring(id)
    end
    return table.concat({
        "p",
        tostring(item.text or ""),
        tostring(item.page or ""),
        posKey(item.pos0),
        posKey(item.pos1),
        tostring(item.datetime or ""),
    }, "\0")
end

local function b64url(data)
    local Text = require("utils.text")
    return (Text.base64Encode(data):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

local function unb64url(s)
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = (4 - #s % 4) % 4
    if pad > 0 then s = s .. string.rep("=", pad) end
    return require("utils.text").base64Decode(s)
end

--- 远程管理等用的跨书条目键（不落库）：source + 书 + 章 + 条目标识，URL 安全。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer|nil
---@param item table
---@return string
function Note.itemKey(source_id, stable_id, chapter_idx, item)
    local raw = table.concat({
        tostring(source_id or ""),
        tostring(stable_id or ""),
        tostring(tonumber(chapter_idx) or 0),
        itemId(item),
    }, "\31")
    return b64url(raw)
end

--- 解开 Note.itemKey。非法输入返回 nil。
---@param key string
---@return { source_id: string, stable_id: string, chapter_idx: integer, item_id: string }|nil
function Note.parseItemKey(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    local ok, raw = pcall(unb64url, key)
    if not ok or type(raw) ~= "string" then
        return nil
    end
    local source_id, stable_id, idx, item_id = raw:match("^(.-)\31(.-)\31(.-)\31(.*)$")
    if not source_id or item_id == nil or item_id == "" then
        return nil
    end
    return {
        source_id = source_id,
        stable_id = stable_id,
        chapter_idx = tonumber(idx) or 0,
        item_id = item_id,
    }
end

---@param item table
---@return table
local function copyItem(item)
    local out = {}
    for k, v in pairs(item) do
        out[k] = v
    end
    return out
end

--- 当前阅读器若正打开同一书/章，把改动写进内存注解和 sidecar，避免下次保存把远程改动盖掉。
---@param source_id string
---@param stable_id string
---@param chapter_idx integer
---@param item_id string
---@param note string|nil
---@param remove boolean
local function patchOpenDocument(source_id, stable_id, chapter_idx, item_id, note, remove)
    local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_ui or not ReaderUI or not ReaderUI.instance then
        return
    end
    local ui = ReaderUI.instance
    local ok_sess, Session = pcall(require, "reader.session")
    local identity = ok_sess and Session and Session._snapshot and Session._snapshot.identity
    if not identity then
        return
    end
    if identity.source_id ~= source_id or identity.stable_id ~= stable_id then
        return
    end
    if (tonumber(identity.chapter_idx) or 0) ~= chapter_idx then
        return
    end
    local live = ui.annotation and ui.annotation.annotations
    if type(live) ~= "table" then
        return
    end
    if remove then
        for i = #live, 1, -1 do
            if type(live[i]) == "table" and itemId(live[i]) == item_id then
                table.remove(live, i)
            end
        end
    else
        for _idx, item in ipairs(live) do
            if type(item) == "table" and itemId(item) == item_id then
                item.note = note
            end
        end
    end
    if ui.doc_settings then
        ui.doc_settings:saveSetting("annotations", live)
        if ui.doc_settings.flush then
            ui.doc_settings:flush()
        end
    end
    if ui.annotation and type(ui.annotation.updateAnnotations) == "function" then
        ui.annotation:updateAnnotations(true)
    end
end

local function maybePushDirty(source_id)
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_net or not NetworkMgr or not NetworkMgr:isConnected() then
        return
    end
    local ok_reg, Registry = pcall(require, "source.registry")
    if not ok_reg or not Registry then
        return
    end
    local source = Registry.resolve(source_id)
    if source and type(source.pushNotesAsync) == "function" and type(source.pushDirty) == "function" then
        source:pushDirty()
    end
end

--- 改一条注解的备注，或从快照里删掉它。
--- 走与阅读器保存相同的清洁 / 源侧墓碑（prepareLocalAnnotations）路径，再脏写 notes 表。
--- 不修改 text / pos0 / pos1 / page，也不新建条目。
---@param opts { key: string, note?: string|nil, remove?: boolean }
---@return boolean ok
---@return string|nil err
function Note.mutate(opts)
    opts = opts or {}
    local parsed = Note.parseItemKey(opts.key)
    if not parsed then
        return false, "invalid key"
    end
    local source_id, stable_id, chapter_idx = parsed.source_id, parsed.stable_id, parsed.chapter_idx
    local row = NoteDB.get(source_id, stable_id, chapter_idx)
    if not row then
        return false, "not found"
    end
    local previous, authoritative = Normalize.decode(row.payload)
    if not previous then
        return false, "invalid snapshot"
    end
    local new_note = type(opts.note) == "string" and Text.trim(opts.note) or nil
    if opts.remove or new_note == "" then new_note = nil end
    local found, deleted
    local current = {}
    for _idx, item in ipairs(previous) do
        if type(item) == "table" and itemId(item) == parsed.item_id
            and not item.wr_deleted and not item.kavita_deleted then
            found = item
            if opts.remove then
                deleted = copyItem(item)
            else
                local copy = copyItem(item)
                copy.note = new_note
                current[#current + 1] = copy
            end
        else
            current[#current + 1] = copyItem(item)
        end
    end
    if not found then
        return false, "not found"
    end
    local source, source_err = require("source.registry").resolve(source_id)
    if not source then
        logger.warn("book.note mutate source unavailable", source_id, source_err)
        return false, source_err or "source unavailable"
    end
    local total_pages = found.total_pages
    local clean = Note.clean(source, current, total_pages)
    if source and type(source.prepareLocalAnnotations) == "function" then
        source:prepareLocalAnnotations(previous, clean, deleted)
    end
    local ok, payload = pcall(JSON.encode, Normalize.pack(clean, authoritative))
    if not ok then
        logger.warn("book.note mutate encode failed", stable_id, payload)
        return false, "encode failed"
    end
    local updated_at = Note.nextRevision()
    if not NoteDB.upsert(source_id, stable_id, chapter_idx, payload, updated_at) then
        logger.warn("book.note mutate save failed", stable_id)
        return false, "save failed"
    end
    patchOpenDocument(source_id, stable_id, chapter_idx, parsed.item_id, new_note, opts.remove == true)
    maybePushDirty(source_id)
    return true
end


return Note
