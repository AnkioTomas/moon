--[[--
阅读会话的注解编排：阅读器注解 ↔ notes 表快照，以及会话内拉取。

落库后的推送 / 拉取收敛在 ``book.note``；这里只碰 ReaderUI。

@module koplugin.book.reader.session.note
--]]

local NoteDB = require("book.note_db")
local logger = require("utils.log")
local Note = require("book.note")
local Normalize = require("book.note.normalize")
local DerivedNote = require("reader.session.derived_note")

local SessionNote = {}

--- 双语章里端点所在的译文元素：返回 (所在段落, 译文元素)，不在译文里返回 nil。
---@param document table
---@param xpointer string
---@return string|nil paragraph, string|nil span
local function translationOf(document, xpointer)
    local classes = require("utils.extension").list("note.markup_classes")
    if #classes == 0 then return nil end
    for at, segment in xpointer:gmatch("()/(span[%[%d%]]*)") do
        local span = xpointer:sub(1, at - 1) .. "/" .. segment
        local html = document:getHTMLFromXPointer(span, 0)
        for _idx, class in ipairs(classes) do
            local prefix = '<span class="' .. class .. '"'
            if html and html:sub(1, #prefix) == prefix then return xpointer:sub(1, at - 1), span end
        end
    end
end

--- 译文元素前的原文末尾：原章没有译文元素（元素 xpointer 原章里找不到，划线不显示），
--- 取译文前最后一个可见字的下一位；取不到再退回译文元素本身。
---@param document table
---@param span string
---@return string
local function endBefore(document, span)
    local prev = document.getPrevVisibleChar and document:getPrevVisibleChar(span)
    if type(prev) ~= "string" or translationOf(document, prev) then return span end
    local base, offset = prev:match("^(.-)%.(%d+)$")
    return base and (base .. "." .. (tonumber(offset) + 1)) or prev
end

--- 双语章：落在译文里的端点退回段内原文（起点退到段首，终点退到译文前），文字随之换成原文。
--- 原文 xpointer 两版通用，存库、上传微信读书、原章 sidecar 都认。
---@param document table
---@param items table[] 就地改
function SessionNote._untranslate(document, items)
    for _idx, item in ipairs(items) do
        if type(item.pos0) == "string" and type(item.pos1) == "string" then
            local para0 = translationOf(document, item.pos0)
            local _para1, span1 = translationOf(document, item.pos1)
            if para0 or span1 then
                item.pos0 = para0 or item.pos0
                item.pos1 = span1 and endBefore(document, span1) or item.pos1
                item.page = item.pos0
                local text = document:getTextFromXPointers(item.pos0, item.pos1)
                if text then item.text = require("utils.text").trim(text) end
            end
        end
    end
end

--- 按章源：注解写到同一章其它版本（原章 / 双语章）的 sidecar，两版的划线、书签、删改一致。
---@param file string
---@param items table[]
local function mirror(file, items)
    for _idx, other in ipairs(require("utils.paths").chapterVariants(file)) do
        local settings = require("docsettings"):open(other)
        settings:saveSetting("annotations", items)
        settings:flush()
    end
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

--- 保存当前文档的完整注解快照。写入完成前不发网络请求。
---@param ui table
---@param identity BookIdentity 当前 ReaderSession 身份
---@param changed table|nil KOReader 的 AnnotationsModified 描述（可选，恒为倒数第二个参数）
---@param done fun(ok: boolean, updated_at: number|nil)|nil
function SessionNote.save(ui, identity, changed, done)
    if not ui or not ui.doc_settings then
        if done then done(false) end
        return
    end
    -- 衍生版的坐标原书不认：划线留在它自己的 sidecar，回原书时由 derived_note 收进来。
    if DerivedNote.originOf(ui.document.file) then
        if done then done(true) end
        return
    end
    local file = ui.document and ui.document.file
    local bilingual = identity.chapter_idx ~= nil and file
        and require("utils.paths").chapterOrigin(file) ~= file
    if bilingual and ui.annotation then
        SessionNote._untranslate(ui.document, ui.annotation.annotations)
        ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
    end
    ui.doc_settings:flush()
    -- ReaderAnnotation 只在 SaveSettings 时才把内存数组写进 doc_settings。
    -- AnnotationsModified 和 CloseDocument 阶段直接读 doc_settings 会拿到旧快照。
    local items = ui.annotation and ui.annotation.annotations
        or ui.doc_settings:readSetting("annotations")
        or {}
    if identity.chapter_idx ~= nil and file then mirror(file, items) end
    local total_pages = pageCount(ui)
    local source_id = identity.source_id
    local stable_id = identity.stable_id
    local chapter_idx = identity.chapter_idx
    local current = NoteDB.get(source_id, stable_id, chapter_idx)
    local source = identity.source
    local clean = Note.clean(source, items, total_pages)
    -- 删除判据：KOReader 唯一的删除通道把被删条目放在 items[1]、index_modified 取负。
    -- 不能只看 nb_highlights_added < 0：划线转笔记、只删备注时它也是负的，但条目还在。
    local deleted
    local modified = type(changed) == "table" and tonumber(changed.index_modified)
    if modified and modified < 0 then deleted = changed[1] end
    if current then
        local previous = Normalize.decode(current.payload)
        if previous and source and type(source.prepareLocalAnnotations) == "function" then
            source:prepareLocalAnnotations(previous, clean, deleted)
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

---@param ui table
---@param identity BookIdentity
---@return integer applied
local function applySnapshot(ui, identity)
    local source = identity.source
    local row = NoteDB.get(identity.source_id, identity.stable_id, identity.chapter_idx)
    local annotations, authoritative = Normalize.decode(row and row.payload)
    if not annotations then
        return 0
    end
    -- 库里可能已有 PHP/JSON 写进来的 note="" / drawer=""；先洗成 nil，否则高亮会被当成笔记。
    annotations = Note.clean(source, annotations)
    local current = ui.doc_settings:readSetting("annotations") or {}
    if source and type(source.localizeAnnotations) == "function" then
        annotations = source:localizeAnnotations(
            ui.document, annotations, ui.document and ui.document.file, current
        )
    end
    if not annotations then
        return 0
    end
    -- 注解形态跟文档走：ReaderUI 只会挂 rolling 或 paging 其中之一。
    -- dropped = 源主动判定为「远端已删」的条数；deduped = 远端同键重复被抑制（不画）的条数。
    -- 两者都是「合并后条数变少」的正当原因（老源不返回第二 / 第三值 ⇒ nil）。
    local dropped, deduped
    if source and type(source.mergeAnnotations) == "function" then
        annotations, dropped, deduped = source:mergeAnnotations(
            annotations, current, ui.paging ~= nil, authoritative
        )
    else
        annotations = Normalize.merge(annotations, current, ui.paging ~= nil)
    end
    -- 合并结果条数少于阅读器现有条数，说明本地有条目被判成不可渲染而被丢弃。
    -- 这里是整体覆盖 doc_settings，写下去就是永久删除用户划线：宁可这次不显示
    -- 云端划线，也不能删本地的。（分页文档的 page 是数字，曾经被误判过一次。）
    -- dropped / deduped 是源给出的明确解释，要算回来，否则合法删除永远被这道保险挡住：
    -- 第一次修正远端重复时 doc_settings 旧有 5 条、合并后 4 条 + deduped 1，不算下来就永远修不掉。
    if #annotations + (dropped or 0) + (deduped or 0) < #current and not authoritative then
        logger.warn("book.note apply skip: merge would drop local annotations",
            identity.stable_id, #current, #annotations, dropped or 0, deduped or 0)
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

--- 把本地 notes 快照定位并写入阅读器注解。
---
--- 纯本地：读 sqlite、算 xpointer、写 doc_settings，不碰网络也不排 nextTick。
--- 必须在文档首次绘制前**同步**跑完，否则云端划线要等下一次刷新才出现。
--- 衍生版（双语版、排版版）的 xpointer 和快照对不上，改由 derived_note 逐条搜索补画；
--- 读原书时顺带把衍生版里的划线收回来。
---@param ui table
---@param identity BookIdentity
---@return integer applied 写入阅读器的注解条数
function SessionNote.applyLocal(ui, identity)
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
    local Perf = require("utils.perf")
    local started_at = Perf.now()
    local applied
    if DerivedNote.originOf(ui.document.file) then
        DerivedNote.project(ui, identity)
        applied = #(ui.doc_settings:readSetting("annotations") or {})
    else
        applied = applySnapshot(ui, identity)
        DerivedNote.collect(ui, identity)
    end
    Perf.slow("note.applyLocal", started_at)
    return applied
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
        SessionNote.save(ui, identity, nil, function(saved)
            if saved then syncAndApply() end
        end)
    else
        syncAndApply()
    end
end

return SessionNote
