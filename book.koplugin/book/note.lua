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

--- 上传数据库中所有未同步注解。网络失败保留对应行。
---@param _ui table|nil 保留入口签名；上传数据完全来自数据库
function Note.push(_ui)
    local sources = {}
    local Registry = require("source.registry")
    for _, row in ipairs(NoteDB.unsynced()) do
        local source = sources[row.source_id]
        if source == nil then
            local resolved, err = Registry.resolve(row.source_id)
            source = resolved or false
            sources[row.source_id] = source
            if not source and err then
                logger.warn("book.note source unavailable", row.source_id, err)
            end
        end
        if source and source.syncAnnotationsAsync then
            local ok, annotations = pcall(JSON.decode, row.payload)
            if not ok or type(annotations) ~= "table" then
                logger.warn("book.note invalid snapshot", row.stable_id)
            else
                local identity = {
                    source_id = row.source_id,
                    stable_id = row.stable_id,
                    chapter_idx = row.chapter_idx ~= 0 and row.chapter_idx or nil,
                }
                source:syncAnnotationsAsync(identity, annotations, function(res, err)
                    if res then
                        confirm(row, function() end)
                    else
                        logger.warn("book.note push failed", row.stable_id, err)
                    end
                end)
            end
        end
    end
end

--- 拉取远端注解前先保存当前快照，避免远端覆盖尚未落盘的本地修改。
---@param ui table
---@param identity BookIdentity
function Note.pull(ui, identity)
    local source = identity and identity.source
    if not source or not source.getAnnotationsAsync then
        return
    end
    Note.save(ui, identity, function(saved, local_revision)
        if not saved then return end
        source:getAnnotationsAsync(identity, function(annotations, err)
            if not Store.isCurrentDocument(ui, identity) then
                logger.dbg("book.note pull skip: document changed")
                return
            end
            if type(annotations) ~= "table" then
                logger.warn("book.note pull failed", identity.stable_id, err)
                return
            end
            local ok, payload = pcall(JSON.encode, clean(annotations, pageCount(ui)))
            if not ok then
                logger.warn("book.note pull encode failed", identity.stable_id, payload)
                return
            end
            local remote_revision = nextRevision()
            local replaced = false
            DbQueue.run(function()
                local current = NoteDB.get(identity.source_id, identity.stable_id, identity.chapter_idx)
                if not current or current.updated_at ~= local_revision then
                    return
                end
                assert(NoteDB.upsert(
                    identity.source_id,
                    identity.stable_id,
                    identity.chapter_idx,
                    payload,
                    remote_revision,
                    true
                ), "failed to save pulled notes")
                replaced = true
            end, {
                on_done = function()
                    if not replaced or not Store.isCurrentDocument(ui, identity) then return end
                    ui.doc_settings:saveSetting("annotations", annotations)
                    ui.doc_settings:flush()
                    if ui.annotation then
                        ui.annotation.annotations = annotations
                    end
                end,
                on_failed = function(save_err)
                    logger.warn("book.note pull save failed", identity.stable_id, save_err)
                end,
            })
        end)
    end)
end

return Note
