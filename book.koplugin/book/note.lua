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

local function nextRevision()
    last_revision = math.max(os.time(), last_revision + 1)
    return last_revision
end

local function clean(items, total_pages)
    local result = {}
    for _, item in ipairs(items or {}) do
        if type(item) == "table" and item.datetime and (item.page or item.pageref) then
            result[#result + 1] = {
                datetime = item.datetime,
                datetime_updated = item.datetime_updated,
                drawer = item.drawer,
                color = item.color,
                text = item.text,
                note = item.note,
                chapter = item.chapter,
                pageno = item.pageno,
                page = item.page or item.pageref,
                total_pages = total_pages or item.total_pages or 0,
                pos0 = item.pos0,
                pos1 = item.pos1,
            }
        end
    end
    return result
end

local function pageCount(ui)
    return ui.document and ui.document.getPageCount
        and tonumber(ui.document:getPageCount())
        or tonumber(ui.doc_settings:readSetting("doc_pages"))
        or 0
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
    local function nextIdentity()
        if cancelled then return end
        local identity = identities[index]
        index = index + 1
        if not identity then finish(result); return end

        local function pullRemote()
            if opts.dirty_only or not can_pull then nextIdentity(); return end
            current_job = source:pullNotesAsync(identity, function(annotations, err)
                current_job = nil
                if cancelled then return end
                if type(annotations) ~= "table" then finish(nil, err or "notes pull failed"); return end
                local ok, payload = pcall(JSON.encode, clean(annotations))
                if not ok then finish(nil, payload); return end
                DbQueue.run(function()
                    assert(NoteDB.upsertRemote(source.id, identity.stable_id,
                        identity.chapter_idx, payload, nextRevision()), "failed to save remote notes")
                end, {
                    on_done = function()
                        result.pulled = result.pulled + 1
                        nextIdentity()
                    end,
                    on_failed = function(save_err) finish(nil, save_err) end,
                })
            end)
        end

        local row = NoteDB.get(source.id, identity.stable_id, identity.chapter_idx)
        if row and row.sync_status == 0 then
            if not can_push then
                result.conflicts = result.conflicts + 1
                nextIdentity()
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
                if not value then finish(nil, err or "notes push failed"); return end
                confirm(row, function(confirmed)
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
    local BookDB = require("utils.db.book")
    local ChapterDB = require("utils.db.chapter")
    local DocSettings = require("docsettings")
    local UIManager = require("ui/uimanager")
    local candidates, seen_paths = {}, {}

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
    local function finish()
        if not cancelled and done then done(result) end
    end
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

--- 拉取远端注解前先保存当前快照，避免远端覆盖尚未落盘的本地修改。
---@param ui table
---@param identity BookIdentity
function Note.pull(ui, identity)
    local source = identity and identity.source
    if not source or not source.syncNotesAsync then
        return
    end
    local function syncAndApply()
        source:syncNotesAsync({ identity = identity }, function(result, err)
            if not Store.isCurrentDocument(ui, identity) then
                logger.dbg("book.note pull skip: document changed")
                return
            end
            if not result then
                logger.warn("book.note pull failed", identity.stable_id, err)
                return
            end
            local row = NoteDB.get(identity.source_id, identity.stable_id, identity.chapter_idx)
            local ok, annotations = pcall(JSON.decode, row and row.payload or "[]")
            if not ok or type(annotations) ~= "table" then return end
            ui.doc_settings:saveSetting("annotations", annotations)
            ui.doc_settings:flush()
            if ui.annotation then ui.annotation.annotations = annotations end
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
