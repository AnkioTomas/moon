--[[--
阅读注解：先持久化完整快照，再经 Source 拉取和推送。

本地 notes 表是唯一的上传来源，避免异步回调发送已被修改的内存表。

@module koplugin.book.book.note
--]]

local JSON = require("json")
local NoteDB = require("db.note")
local logger = require("utils.log")
local Store = require("book.store")
local Normalize = require("book.note.normalize")

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

--- 取文档总页数：优先问 document，退回 doc_settings 里的 doc_pages，都没有算 0。
---@param ui table ReaderUI
---@return integer
local function pageCount(ui)
    return ui.document and ui.document.getPageCount
        and tonumber(ui.document:getPageCount())
        or tonumber(ui.doc_settings:readSetting("doc_pages"))
        or 0
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
            local key = Normalize.bucketKey(item)
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
    local revision = nextRevision()
    local ok = true
    for key, items in pairs(buckets) do
        local chapter_idx = key > 0 and key or nil
        local encoded, payload = pcall(JSON.encode, Normalize.clean(items))
        ok = encoded and NoteDB.upsertRemote(source_id, stable_id, chapter_idx, payload, revision)
        if not ok then
            logger.warn("book.note remote bucket failed", stable_id, chapter_idx, not encoded and payload or nil)
            break
        end
    end
    if done then done(ok) end
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
    local ok, payload = pcall(JSON.encode, Normalize.clean(items, total_pages))
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
    local saved = NoteDB.upsert(source_id, stable_id, chapter_idx, payload, updated_at)
    if not saved then logger.warn("book.note save failed", stable_id) end
    if done then done(saved, saved and updated_at or nil) end
end

--- 上传成功后落定这一版快照：写回源侧回填过 id 的 payload 并标记已同步。
---
--- 读-比对-写在同一个同步调用中，保持原子性。
--- 上传期间用户又划了线（updated_at 变了）时整条跳过——既不覆盖新内容，也不清脏
--- 标记，下轮同步重新上传。
---@param row table notes 表行（含 source_id/stable_id/chapter_idx/updated_at）
---@param payload string|nil 源侧回填过远端 id 的快照
---@param done fun(ok: boolean, stale: boolean|nil)
local function confirm(row, payload, done)
    local live = NoteDB.get(row.source_id, row.stable_id, row.chapter_idx)
    if not live or live.updated_at ~= row.updated_at then
        done(false, true)
        return
    end
    local ok = NoteDB.markSynced(row.source_id, row.stable_id, row.chapter_idx, row.updated_at, payload)
    if not ok then logger.warn("book.note confirm failed", row.stable_id) end
    done(ok)
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
        for _, stable_id in ipairs(require("db.book").libraryStableIdsBySource(source.id)) do
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
                -- 源侧（如 wechat.lua）在上传过程中把远端分配的 wr_bookmark_id /
                -- wr_review_id 原地写进了 annotations，必须落库，否则下轮会重复上传。
                local ok_encode, pushed_payload = pcall(JSON.encode, Normalize.clean(annotations))
                if not ok_encode then
                    finish(nil, "invalid local notes")
                    return
                end
                confirm(row, pushed_payload, function(confirmed, stale)
                    if stale then
                        -- 上传期间本地又改过：这次算推成功，但脏标记留着下轮再推
                        logger.dbg("book.note confirm skipped: local changed during push",
                            row.stable_id)
                        result.pushed = result.pushed + 1
                        pullRemote()
                        return
                    end
                    if not confirmed then finish(nil, "notes confirm failed"); return end
                    result.pushed = result.pushed + 1
                    pullRemote()
                end)
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
    local BookDB = require("db.book")
    local ChapterDB = require("db.chapter")
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
                local normalized = Normalize.clean(annotations, total_pages)
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
        if NoteDB.get(candidate.source_id, candidate.stable_id, candidate.chapter_idx) then
            result.skipped = result.skipped + 1
        elseif NoteDB.upsert(candidate.source_id, candidate.stable_id, candidate.chapter_idx,
            payload, nextRevision()) then
            result.imported = result.imported + 1
        else
            logger.warn("book.note import failed", candidate.path)
            result.failed = result.failed + 1
        end
        UIManager:nextTick(nextItem)
    end

    UIManager:nextTick(nextItem)
    return { cancel = function() cancelled = true end }
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
    -- 注解形态跟文档走：ReaderUI 只会挂 rolling 或 paging 其中之一
    annotations = Normalize.merge(annotations, current, ui.paging ~= nil)
    -- 合并结果条数少于阅读器现有条数，说明本地有条目被判成不可渲染而被丢弃。
    -- 这里是整体覆盖 doc_settings，写下去就是永久删除用户划线：宁可这次不显示
    -- 云端划线，也不能删本地的。（分页文档的 page 是数字，曾经被误判过一次。）
    if #annotations < #current then
        logger.warn("book.note apply skip: merge would drop local annotations",
            identity.stable_id, #current, #annotations)
        return 0
    end
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
