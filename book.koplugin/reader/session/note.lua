--[[--
阅读会话的注解编排：阅读器注解 ↔ notes 表快照，以及会话内拉取。

落库后的推送 / 拉取收敛在 ``book.note``；这里只碰 ReaderUI。

@module koplugin.book.reader.session.note
--]]

local NoteDB = require("book.note_db")
local logger = require("utils.log")
local Note = require("book.note")
local Normalize = require("book.note.normalize")

local SessionNote = {}

--- 取文档总页数：优先问 document，退回 doc_settings 里的 doc_pages，都没有算 0。
---@param ui table ReaderUI
---@return integer
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
function SessionNote.save(ui, identity, done)
    if not ui or not ui.doc_settings then
        if done then done(false) end
        return
    end
    ui.doc_settings:flush()
    -- ReaderAnnotation 只在 SaveSettings 时才把内存数组写进 doc_settings。
    -- AnnotationsModified 和 CloseDocument 阶段直接读 doc_settings 会拿到旧快照。
    local items = ui.annotation and ui.annotation.annotations
        or ui.doc_settings:readSetting("annotations")
        or {}
    local total_pages = pageCount(ui)
    local source_id = identity.source_id
    local stable_id = identity.stable_id
    local chapter_idx = identity.chapter_idx
    local current = NoteDB.get(source_id, stable_id, chapter_idx)
    local source = identity.source
    local clean = Note.clean(source, items, total_pages)
    if current then
        local previous = Normalize.decode(current.payload)
        if previous and source and type(source.prepareLocalAnnotations) == "function" then
            source:prepareLocalAnnotations(previous, clean)
        end
    end
    local ok, payload = pcall(require("json").encode, clean)
    if not ok then
        logger.warn("book.note encode failed", identity.stable_id, payload)
        if done then done(false) end
        return
    end
    if current and current.payload == payload then
        if done then done(true, current.updated_at) end
        return
    end
    local updated_at = Note.nextRevision()
    local saved = NoteDB.upsert(source_id, stable_id, chapter_idx, payload, updated_at)
    if not saved then logger.warn("book.note save failed", stable_id) end
    if done then done(saved, saved and updated_at or nil) end
end

--- 把本地 notes 快照定位并写入阅读器注解。
---
--- 纯本地：读 sqlite、算 xpointer、写 doc_settings，不碰网络也不排 nextTick。
--- 必须在文档首次绘制前**同步**跑完，否则云端划线要等下一次刷新才出现。
---@param ui table
---@param identity BookIdentity
---@return integer applied 写入阅读器的注解条数
function SessionNote.applyLocal(ui, identity)
    local source = identity and identity.source
    if not ui or not ui.doc_settings or not identity then
        return 0
    end
    -- 异步回调回来时阅读器可能已换了文档（或同书换了章）
    local current_id = ui.document and ui.document.file
        and require("book.store").identityFor(ui.document.file)
    if not current_id
            or current_id.source_id ~= identity.source_id
            or current_id.stable_id ~= identity.stable_id
            or current_id.chapter_idx ~= identity.chapter_idx then
        logger.dbg("book.note apply skip: document changed")
        return 0
    end
    local row = NoteDB.get(identity.source_id, identity.stable_id, identity.chapter_idx)
    local annotations, authoritative = Normalize.decode(row and row.payload)
    if not annotations then
        return 0
    end
    local current = ui.doc_settings:readSetting("annotations") or {}
    if source and type(source.localizeAnnotations) == "function" then
        annotations = source:localizeAnnotations(
            ui.document, annotations, ui.document and ui.document.file, current
        )
    end
    if not annotations then
        return 0
    end
    -- 注解形态跟文档走：ReaderUI 只会挂 rolling 或 paging 其中之一
    if source and type(source.mergeAnnotations) == "function" then
        annotations = source:mergeAnnotations(
            annotations, current, ui.paging ~= nil, authoritative
        )
    else
        annotations = Normalize.merge(annotations, current, ui.paging ~= nil)
    end
    -- 合并结果条数少于阅读器现有条数，说明本地有条目被判成不可渲染而被丢弃。
    -- 这里是整体覆盖 doc_settings，写下去就是永久删除用户划线：宁可这次不显示
    -- 云端划线，也不能删本地的。（分页文档的 page 是数字，曾经被误判过一次。）
    if #annotations < #current and not authoritative then
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
--- 只负责「网络同步 → 落库 → 重画」；首屏渲染由 ``SessionNote.applyLocal`` 负责。
---@param ui table
---@param identity BookIdentity
function SessionNote.pull(ui, identity)
    local source = identity and identity.source
    if not source or not source.syncNotesAsync then
        return
    end
    local UIManager = require("ui/uimanager")
    --- 用库里最新快照重写阅读器注解；条数变了才请求局部重画。
    local function applyFromDb()
        local before = ui.doc_settings and #(ui.doc_settings:readSetting("annotations") or {}) or 0
        if SessionNote.applyLocal(ui, identity) ~= before and ui.view then
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
            UIManager:nextTick(require("ui.guard").wrap("notes apply", applyFromDb))
        end)
    end
    local existing = NoteDB.get(identity.source_id, identity.stable_id, identity.chapter_idx)
    local current = ui.doc_settings:readSetting("annotations") or {}
    if existing or #current > 0 then
        SessionNote.save(ui, identity, function(saved)
            if saved then syncAndApply() end
        end)
    else
        syncAndApply()
    end
end

return SessionNote
