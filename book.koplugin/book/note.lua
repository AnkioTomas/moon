--[[--
阅读注解：先持久化完整快照，再经 Source 拉取和推送。

本地 notes 表是唯一的上传来源，避免异步回调发送已被修改的内存表。

@module koplugin.book.book.note
--]]

local JSON = require("json")
local NoteDB = require("utils.db.note")
local DbQueue = require("utils.db.queue")
local logger = require("logger")
local Store = require("book.store")

local Note = {}
local last_revision = 0

--- 生成单调递增的注解修订号（同一进程内不会重复）。
--- 取 os.time() 与上次值+1 的较大者：秒级时间戳在同一秒内多次写入会撞号，
--- 而修订号是 notes 表判定新旧的依据，必须严格递增。
---@return integer
local function nextRevision()
    last_revision = math.max(os.time(), last_revision + 1)
    return last_revision
end

--- 归一化注解快照。
---
--- 远端划线在开章定位前只有 ``wr_range``，没有本地坐标——不要为了凑 ``page`` 造假值：
--- ReaderAnnotation:onReadSettings 用 ``type(annotations[1].page)`` 判断整个数组是
--- crengine 还是 mupdf 格式，一个数字 ``page`` 会让整份注解（含本地划线）被搬去
--- ``annotations_paging`` 并加载空表。
---@param items table[]|nil
---@param total_pages integer|nil
---@return table[]
local function clean(items, total_pages)
    local result = {}
    for _, item in ipairs(items or {}) do
        if type(item) == "table" and item.datetime
            and (item.page or item.pageref or item.wr_range) then
            result[#result + 1] = {
                datetime = item.datetime,
                datetime_updated = item.datetime_updated,
                drawer = item.drawer,
                color = item.color,
                text = item.text,
                note = item.note,
                chapter = item.chapter,
                chapter_idx = item.chapter_idx,
                pageno = item.pageno,
                page = item.page or item.pageref,
                total_pages = total_pages or item.total_pages or 0,
                pos0 = item.pos0,
                pos1 = item.pos1,
                wr_range = item.wr_range,
                wr_bookmark_id = item.wr_bookmark_id,
                wr_review_id = item.wr_review_id,
            }
        end
    end
    return result
end

--- 取文档总页数：优先问 document，退回 doc_settings 里的 doc_pages，都没有算 0。
---@param ui table ReaderUI
---@return integer
local function pageCount(ui)
    return ui.document and ui.document.getPageCount
        and tonumber(ui.document:getPageCount())
        or tonumber(ui.doc_settings:readSetting("doc_pages"))
        or 0
end

---@param item table
---@return integer
local function bucketKey(item)
    local idx = tonumber(item.chapter_idx)
    if idx and idx > 0 then
        return idx
    end
    return 0
end

--- 远端注解按 ``chapter_idx`` 分片落库（payload 一律为通用 KOReader 注解数组）。
---
--- 只覆盖远端确实报告了的分片：远端一条都没报时不写任何分片。协议字段缺失与
--- 「远端确实为空」在 wire 上无法区分，宁可漏掉云端删除，也不能把本地划线清空。
---@param source_id string
---@param stable_id string
---@param annotations table[]
---@param done fun(ok: boolean)|nil
local function saveRemoteBuckets(source_id, stable_id, annotations, done)
    local buckets = {}
    for _, item in ipairs(annotations or {}) do
        if type(item) == "table" then
            local key = bucketKey(item)
            local bucket = buckets[key]
            if not bucket then
                bucket = {}
                buckets[key] = bucket
            end
            bucket[#bucket + 1] = item
        end
    end
    if not next(buckets) then
        if done then done(true) end
        return
    end
    DbQueue.run(function()
        local revision = nextRevision()
        for key, items in pairs(buckets) do
            local chapter_idx = key > 0 and key or nil
            local ok, payload = pcall(JSON.encode, clean(items))
            assert(ok, payload)
            assert(NoteDB.upsertRemote(
                source_id, stable_id, chapter_idx, payload, revision
            ), "failed to save remote notes")
        end
    end, {
        on_done = function()
            if done then done(true) end
        end,
        on_failed = function(err)
            logger.warn("book.note remote buckets failed", stable_id, err)
            if done then done(false) end
        end,
    })
end

--- 保存当前文档的完整注解快照。写入完成前不发网络请求。
---@param ui table
---@param identity BookIdentity 当前 ReaderSession 身份
---@param done fun(ok: boolean, updated_at: number|nil)|nil
---@return nil
function Note.save(ui, identity, done)
    if not ui or not ui.doc_settings then
        if done then done(false) end
        return
    end
    ui.doc_settings:flush()
    local items = ui.doc_settings:readSetting("annotations") or {}
    local total_pages = pageCount(ui)
    local ok, payload = pcall(JSON.encode, clean(items, total_pages))
    if not ok then
        logger.warn("book.note encode failed", identity.stable_id, payload)
        if done then done(false) end
        return
    end
    local source_id = identity.source_id
    local stable_id = identity.stable_id
    local chapter_idx = identity.chapter_idx
    local current = NoteDB.get(source_id, stable_id, chapter_idx)
    if current and current.payload == payload then
        if done then done(true, current.updated_at) end
        return
    end
    local updated_at = nextRevision()
    DbQueue.run(function()
        assert(NoteDB.upsert(source_id, stable_id, chapter_idx, payload, updated_at), "failed to save notes")
    end, {
        on_done = function() if done then done(true, updated_at) end end,
        on_failed = function(err)
            logger.warn("book.note save failed", stable_id, err)
            if done then done(false) end
        end,
    })
end

--- 把一条 notes 记录标记为已同步（按 row.updated_at 做乐观校验）。
--- 若期间本地又改过（updated_at 已变），markSynced 不会误清脏标记。
---@param row table notes 表行（含 source_id/stable_id/chapter_idx/updated_at）
---@param done fun(ok: boolean)
local function confirm(row, done)
    DbQueue.run(function()
        assert(NoteDB.markSynced(row.source_id, row.stable_id, row.chapter_idx, row.updated_at),
            "failed to confirm notes")
    end, {
        on_done = function() done(true) end,
        on_failed = function(err)
            logger.warn("book.note confirm failed", row.stable_id, err)
            done(false)
        end,
    })
end

--- 将一个 Source 的注解快照与远端收敛。本地脏快照先上传。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
function Note.syncAsync(source, opts, cb)
    opts = opts or {}
    local can_pull = source and type(source.pullNotesAsync) == "function"
    local can_push = source and type(source.pushNotesAsync) == "function"
    local cancelled, current_job = false, nil
    local result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    --- 终结整次同步并回调；已取消时静默丢弃。
    ---@param value SyncResult|nil nil 表示失败
    ---@param err any
    local function finish(value, err)
        if not cancelled and cb then cb(value, err) end
    end
    if not source or (not can_pull and not can_push) then
        require("ui/uimanager"):nextTick(function()
            result.skipped, result.reason = true, "unsupported"
            finish(result)
        end)
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
        for _, stable_id in ipairs(require("utils.db.book").libraryStableIdsBySource(source.id)) do
            add(stable_id)
        end
    end
    if not opts.identity then
        for _, row in ipairs(NoteDB.unsynced(source.id)) do
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
            current_job = source:pullNotesAsync(identity, function(annotations, err)
                current_job = nil
                if cancelled then return end
                if type(annotations) ~= "table" then finish(nil, err or "notes pull failed"); return end
                book_pulled[stable_id] = true
                saveRemoteBuckets(source.id, stable_id, annotations, function(ok)
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
            local ok, annotations = pcall(JSON.decode, row.payload)
            if not ok or type(annotations) ~= "table" then
                finish(nil, "invalid local notes")
                return
            end
            current_job = source:pushNotesAsync(identity, annotations, function(value, err)
                current_job = nil
                if cancelled then return end
                if not value then
                    result.conflicts = result.conflicts + 1
                    if opts.dirty_only then
                        nextIdentity()
                    elseif can_pull then
                        pullRemote()
                    else
                        finish(nil, err or "notes push failed")
                    end
                    return
                end
                local ok_encode, pushed_payload = pcall(JSON.encode, clean(annotations))
                if not ok_encode then
                    finish(nil, "invalid local notes")
                    return
                end
                DbQueue.run(function()
                    assert(NoteDB.upsert(
                        row.source_id, row.stable_id, row.chapter_idx,
                        pushed_payload, row.updated_at, false
                    ), "failed to persist pushed notes")
                end, {
                    on_done = function()
                        confirm(row, function(confirmed)
                            if not confirmed then finish(nil, "notes confirm failed"); return end
                            result.pushed = result.pushed + 1
                            pullRemote()
                        end)
                    end,
                    on_failed = function(persist_err)
                        logger.warn("book.note persist pushed failed", row.stable_id, persist_err)
                        finish(nil, "failed to persist pushed notes")
                    end,
                })
            end)
            return
        end
        pullRemote()
    end
    require("ui/uimanager"):nextTick(nextIdentity)
    return {
        cancel = function()
            cancelled = true
            if current_job and current_job.cancel then current_job:cancel() end
        end,
    }
end

--- 把已登记书籍的 KOReader Lua 注解导入 notes 表。
--- 仅插入没有本地快照的身份，不覆盖新格式写入的未同步数据。
---@param done fun(result: { imported: integer, skipped: integer, failed: integer })|nil
---@return { cancel: fun() }
function Note.importLocalAsync(done)
    local BookDB = require("utils.db.book")
    local ChapterDB = require("utils.db.chapter")
    local DocSettings = require("docsettings")
    local UIManager = require("ui/uimanager")
    local candidates, seen_paths = {}, {}

    --- 登记一个待导入候选，按物理路径去重（同一文件只导一次）。
    ---@param path string|nil 非字符串或空串忽略
    ---@param source_id string
    ---@param stable_id string
    ---@param chapter_idx integer|nil nil 表示整本书
    local function add(path, source_id, stable_id, chapter_idx)
        if type(path) ~= "string" or path == "" or seen_paths[path] then return end
        seen_paths[path] = true
        candidates[#candidates + 1] = {
            path = path,
            source_id = source_id,
            stable_id = stable_id,
            chapter_idx = chapter_idx,
        }
    end

    for _, row in ipairs(BookDB.pathsAll()) do
        add(row.path, row.source_id, row.stable_id, nil)
    end
    for _, row in ipairs(ChapterDB.all()) do
        add(row.path, row.source_id, row.stable_id, row.chapter_idx)
    end

    local i, cancelled = 1, false
    local result = { imported = 0, skipped = 0, failed = 0 }
    --- 回报导入统计；已取消时静默丢弃。
    local function finish()
        if not cancelled and done then done(result) end
    end
    --- 处理下一个候选文件：读 DocSettings 注解 → 归一化 → 仅在无本地快照时插入。
    --- 每个候选占一个 nextTick，避免一次性遍历全库卡住 UI。
    local function nextItem()
        if cancelled then return end
        local candidate = candidates[i]
        i = i + 1
        if not candidate then
            finish()
            return
        end

        local ok, settings = pcall(DocSettings.open, DocSettings, candidate.path)
        local annotations = ok and settings and settings:readSetting("annotations") or nil
        if type(annotations) ~= "table" or #annotations == 0 then
            result.skipped = result.skipped + 1
            UIManager:nextTick(nextItem)
            return
        end
        local total_pages = tonumber(settings:readSetting("doc_pages")) or 0
        local normalized = clean(annotations, total_pages)
        if #normalized == 0 then
            result.skipped = result.skipped + 1
            UIManager:nextTick(nextItem)
            return
        end
        local encoded, payload = pcall(JSON.encode, normalized)
        if not encoded then
            logger.warn("book.note import encode failed", candidate.path, payload)
            result.failed = result.failed + 1
            UIManager:nextTick(nextItem)
            return
        end
        local inserted = false
        DbQueue.run(function()
            if NoteDB.get(candidate.source_id, candidate.stable_id, candidate.chapter_idx) then
                return
            end
            assert(NoteDB.upsert(
                candidate.source_id,
                candidate.stable_id,
                candidate.chapter_idx,
                payload,
                nextRevision()
            ), "failed to import notes")
            inserted = true
        end, {
            on_done = function()
                if inserted then result.imported = result.imported + 1
                else result.skipped = result.skipped + 1 end
                UIManager:nextTick(nextItem)
            end,
            on_failed = function(err)
                logger.warn("book.note import failed", candidate.path, err)
                result.failed = result.failed + 1
                UIManager:nextTick(nextItem)
            end,
        })
    end

    UIManager:nextTick(nextItem)
    return { cancel = function() cancelled = true end }
end

--- 能否交给 KOReader 渲染（rolling 文档）。
---
--- 两条硬约束，任一不满足都不能进 doc_settings：
--- 1. ``page`` 必须是 xpointer 字符串，否则 onReadSettings 会判定整份注解是 mupdf
---    格式，连本地划线一起搬去 ``annotations_paging``；
--- 2. 带 ``drawer`` 的必须有 pos0/pos1，否则 ReaderView:drawSavedHighlight 直接
---    ``getPosFromXPointer(nil)`` 抛错终止绘制。
---
--- 远端划线在开章定位成功前只留在 notes 表里。
---@param item table
---@return boolean
local function renderable(item)
    -- page 必须是 xpointer 字符串：onReadSettings 拿首条的 page 类型判定整个数组的格式。
    if type(item.page) ~= "string" or item.page == "" then
        return false
    end
    if not item.drawer then
        return true
    end
    return type(item.pos0) == "string" and item.pos0 ~= ""
        and type(item.pos1) == "string" and item.pos1 ~= ""
end

--- 合并远端划线与本地未同步划线（保留无 wr_bookmark_id 的本地高亮）。
---@param remote table[]
---@param local_items table[]
---@return table[]
local function mergeAnnotations(remote, local_items)
    local merged, seen = {}, {}
    for _, item in ipairs(remote or {}) do
        if type(item) == "table" and renderable(item) then
            local key = item.wr_bookmark_id
                or table.concat({ tostring(item.text or ""), tostring(item.wr_range or "") }, "\31")
            seen[key] = true
            merged[#merged + 1] = item
        end
    end
    for _, item in ipairs(local_items or {}) do
        if type(item) == "table" and not item.wr_bookmark_id and renderable(item) then
            merged[#merged + 1] = item
        end
    end
    return merged
end

--- 把本地 notes 快照定位并写入阅读器注解。
---
--- 纯本地：读 sqlite、算 xpointer、写 doc_settings，不碰网络也不排 nextTick。
--- 必须在文档首次绘制前**同步**跑完，否则云端划线要等下一次刷新才出现。
---@param ui table
---@param identity BookIdentity
---@return integer applied 写入阅读器的注解条数
function Note.applyLocal(ui, identity)
    local source = identity and identity.source
    if not ui or not ui.doc_settings or not identity then
        return 0
    end
    if not Store.isCurrentDocument(ui, identity) then
        logger.dbg("book.note apply skip: document changed")
        return 0
    end
    local row = NoteDB.get(identity.source_id, identity.stable_id, identity.chapter_idx)
    local ok, annotations = pcall(JSON.decode, row and row.payload or "[]")
    if not ok or type(annotations) ~= "table" then
        return 0
    end
    if source and type(source.localizeAnnotations) == "function" then
        annotations = source:localizeAnnotations(
            ui.document, annotations, ui.document and ui.document.file
        )
    end
    local current = ui.doc_settings:readSetting("annotations") or {}
    annotations = mergeAnnotations(annotations, current)
    if #annotations == 0 and #current == 0 then
        return 0
    end
    ui.doc_settings:saveSetting("annotations", annotations)
    ui.doc_settings:flush()
    if ui.annotation then
        ui.annotation.annotations = annotations
        -- 远端划线的定位顺序与文档顺序无关，而 drawSavedHighlight 靠有序 break 提前退出。
        ui.annotation:updateAnnotations(true)
    end
    return #annotations
end

--- 拉取远端注解前先保存当前快照，避免远端覆盖尚未落盘的本地修改。
---
--- 只负责「网络同步 → 落库 → 重画」；首屏渲染由 ``Note.applyLocal`` 负责。
---@param ui table
---@param identity BookIdentity
function Note.pull(ui, identity)
    local source = identity and identity.source
    if not source or not source.syncNotesAsync then
        return
    end
    local UIManager = require("ui/uimanager")
    --- 用库里最新快照重写阅读器注解；条数变了才请求局部重画。
    local function applyFromDb()
        local before = ui.doc_settings and #(ui.doc_settings:readSetting("annotations") or {}) or 0
        if Note.applyLocal(ui, identity) ~= before and ui.view then
            UIManager:setDirty(ui.view.dialog or "all", "partial")
        end
    end
    --- 走属主源做一次注解同步，成功后在下一 tick 应用到阅读器。
    --- 同步失败只记日志：注解拉不下来不该影响正在进行的阅读。
    local function syncAndApply()
        source:syncNotesAsync({ identity = identity }, function(result, err)
            if not result then
                logger.warn("book.note pull failed", identity.stable_id, err)
                return
            end
            UIManager:nextTick(applyFromDb)
        end)
    end
    local existing = NoteDB.get(identity.source_id, identity.stable_id, identity.chapter_idx)
    local current = ui.doc_settings:readSetting("annotations") or {}
    if existing or #current > 0 then
        Note.save(ui, identity, function(saved)
            if saved then syncAndApply() end
        end)
    else
        syncAndApply()
    end
end

return Note
