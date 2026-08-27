--[[--
阅读进度：输出 ProgressPosition，经 Source 拉/推。
本地进度写入 pending_progress；上传仅处理未同步行。

@module koplugin.book.book.progress
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local ProgressDB = require("utils.db.progress")
local DbQueue = require("utils.db.queue")
local ProgressPosition = require("types.book_progress")
local _ = require("gettext")

local Progress = {}
local asked_conflicts = {}
local last_revision = 0

local function nextRevision()
    last_revision = math.max(os.time(), last_revision + 1)
    return last_revision
end

local function T(fmt, value)
    return tostring(fmt):gsub("%%1", tostring(value), 1)
end
--- 把文档内比例合成为全书比例。
---@param doc_frac number
---@param id BookIdentity|nil
---@param toc BookChapter[]|nil
---@return number
local function wholeFraction(doc_frac, id, toc)
    if not id or not id.chapter_idx then
        return doc_frac
    end
    local count = toc and #toc
    local idx = tonumber(id.chapter_idx) or 1
    if not count or count <= 0 then
        return doc_frac
    end
    return math.max(0, math.min(1, ((idx - 1) + doc_frac) / count))
end

--- 从阅读快照取得全书阅读比例 0..1（按章源会合成）。
---@param snapshot ReaderSessionSnapshot
---@return number
function Progress.fraction(snapshot)
    if not snapshot then return 0 end
    local doc_frac = tonumber(snapshot.doc_fraction) or 0
    local identity = snapshot.identity
    local chapter = snapshot.chapter
    return wholeFraction(doc_frac, identity, chapter and chapter.toc)
end

--- 当前章节标题（顶栏 / 进度上报共用）。
---@param snapshot ReaderSessionSnapshot|nil
---@return string
function Progress.chapterTitle(snapshot)
    return require("ui.reader.session").chapterTitle(snapshot) or ""
end

--- 当前 ProgressPosition；位置完全来自 ReaderSession 快照。
---@param snapshot ReaderSessionSnapshot
---@return ProgressPosition
function Progress.position(snapshot)
    local id = snapshot and snapshot.identity or {}
    local doc_frac = snapshot and tonumber(snapshot.doc_fraction) or 0
    local page = tonumber(snapshot and snapshot.page)
    local total_pages = tonumber(snapshot and snapshot.total_pages)
    local Session = require("ui.reader.session")
    return {
        fraction = Progress.fraction(snapshot),
        chapter_idx = id.chapter_idx,
        chapter_title = Session.chapterTitle(snapshot),
        chapter_fraction = id.chapter_idx and doc_frac or nil,
        page = page and page > 0 and math.floor(page) or nil,
        total_pages = total_pages and total_pages > 0 and math.floor(total_pages) or nil,
    }
end

--- 把比例应用到当前文档（XPointer 或页码）。
---@param ui table
---@param pct number
local function applyFractionToDoc(ui, pct)
    pct = ProgressPosition.clampFraction(pct)
    if ui.document and ui.document.getXPointerFromProportion then
        local xptr = ui.document:getXPointerFromProportion(pct)
        if xptr and ui.rolling then
            ui.rolling:onGotoXPointer(xptr)
        elseif xptr and ui.link then
            ui.link:onGotoXPointer(xptr)
        end
    elseif ui.document and ui.document.getPageCount then
        local total = ui.document:getPageCount() or 1
        local page = math.max(1, math.min(total, math.floor(pct * total + 0.5)))
        ui:handleEvent(Event:new("GotoPage", page))
    end
end

--- 把章内/文档比例应用到当前 ReaderUI（XPointer 或页码）。
---@param ui table
---@param pct number
function Progress.applyFractionToDoc(ui, pct)
    applyFractionToDoc(ui, pct)
end

--- 冷打开：pending 章序号与当前身份一致时应用章内比例。
---@param snapshot ReaderSessionSnapshot
function Progress.applyLocalPending(snapshot)
    local id = snapshot and snapshot.identity
    if not id or not id.chapter_idx or not snapshot.ui then return end
    local row = ProgressDB.get(id.source_id, id.stable_id)
    if not row or tonumber(row.chapter_idx) ~= tonumber(id.chapter_idx) then return end
    if row.chapter_fraction == nil then return end
    applyFractionToDoc(snapshot.ui, row.chapter_fraction)
end

--- 服务端确认后标记对应本地版本已同步；新版本不会被旧回调覆盖。
---@param source_id string
---@param stable_id string
---@param revision integer
---@param done fun(ok: boolean)
local function confirm(source_id, stable_id, revision, done)
    DbQueue.run(function()
        assert(ProgressDB.markSynced(source_id, stable_id, revision), "failed to confirm progress")
    end, {
        on_done = function() done(true) end,
        on_failed = function(err)
            logger.warn("book.progress confirm failed", stable_id, err)
            done(false)
        end,
    })
end

--- 保存当前文档进度。写入完成前不发网络请求，避免同步旧快照。
---@param snapshot ReaderSessionSnapshot
---@param cb fun(ok: boolean)|nil
function Progress.save(snapshot, cb)
    local id = snapshot and snapshot.identity
    if not id or not id.source_id or not id.stable_id then
        if cb then cb(false) end
        return
    end
    local pos = Progress.position(snapshot)
    pos.updated_at = nextRevision()
    DbQueue.run(function()
        assert(ProgressDB.upsert(id.source_id, id.stable_id, pos), "failed to save progress")
    end, {
        on_done = function()
            if cb then cb(true) end
        end,
        on_failed = function(err)
            logger.warn("book.progress save failed", id.stable_id, err)
            if cb then cb(false) end
        end,
    })
end

---@param row PendingProgress
---@return ProgressPosition
local function rowPosition(row)
    return {
        fraction = row.fraction,
        chapter_idx = row.chapter_idx,
        chapter_title = row.chapter_title,
        chapter_fraction = row.chapter_fraction,
        page = row.page,
        total_pages = row.total_pages,
        locator = row.locator,
    }
end

--- 将一个 Source 的本地进度与远端收敛。本地脏版本先上传，干净后才拉取。
---@param source BookSource
---@param opts { identity?: BookIdentity, dirty_only?: boolean }|nil
---@param cb fun(result: SyncResult|nil, err: any)|nil
---@return { cancel: fun() }
function Progress.syncAsync(source, opts, cb)
    opts = opts or {}
    local can_pull = source and type(source.getProgressAsync) == "function"
    local can_push = source and type(source.putProgressAsync) == "function"
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
    local function add(source_id, stable_id, chapter_idx)
        local key = tostring(stable_id) .. "\31" .. tostring(chapter_idx or 0)
        if stable_id and stable_id ~= "" and not seen[key] then
            seen[key] = true
            identities[#identities + 1] = {
                source_id = source_id, stable_id = stable_id, chapter_idx = chapter_idx,
            }
        end
    end
    if opts.identity then
        add(source.id, opts.identity.stable_id, opts.identity.chapter_idx)
    elseif not opts.dirty_only then
        for _, stable_id in ipairs(require("utils.db.book").libraryStableIdsBySource(source.id)) do
            add(source.id, stable_id)
        end
    end
    if not opts.identity then
        for _, row in ipairs(ProgressDB.unsynced(source.id)) do
            add(source.id, row.stable_id, row.chapter_idx)
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
            current_job = source:getProgressAsync(identity, function(pos, err)
                current_job = nil
                if cancelled then return end
                if not pos then finish(nil, err or "progress pull failed"); return end
                DbQueue.run(function()
                    pos.updated_at = os.time()
                    assert(ProgressDB.upsertRemote(source.id, identity.stable_id, pos),
                        "failed to save remote progress")
                end, {
                    on_done = function()
                        result.pulled = result.pulled + 1
                        nextIdentity()
                    end,
                    on_failed = function(save_err) finish(nil, save_err) end,
                })
            end)
        end

        local row = ProgressDB.get(source.id, identity.stable_id)
        if row and row.sync_status == 0 then
            if not can_push then
                result.conflicts = result.conflicts + 1
                nextIdentity()
                return
            end
            current_job = source:putProgressAsync(identity, rowPosition(row), function(ok, err)
                current_job = nil
                if cancelled then return end
                if ok ~= true then finish(nil, err or "progress push failed"); return end
                confirm(source.id, identity.stable_id, row.updated_at, function(confirmed)
                    if not confirmed then finish(nil, "progress confirm failed"); return end
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

--- 把云端进度应用到当前文档（按章书跳章，整本书跳比例）。
--- 调用前提：已确认 pos 与本地不一致且文档身份未变。
--- 只有活动的按章会话才允许用远端进度切章；冷打开的章节文件按单文档处理。
---@param ui table
---@param id BookIdentity
---@param pos ProgressPosition
---@param pct number clamp 后的全书比例
---@param show_msg boolean|nil
local function applyRemotePos(ui, id, pos, pct, show_msg)
    local toc = require("ui.reader.session").toc()
    if toc then
        local count = #toc
        local target_idx = pos.chapter_idx
        local within
        if pos.chapter_fraction ~= nil then
            within = pos.chapter_fraction
        elseif not target_idx then
            local p = pct * count
            target_idx = math.max(1, math.min(count, math.floor(p) + 1))
            within = p - (target_idx - 1)
        else
            local p = pct * count
            local expect = math.floor(p) + 1
            if expect == target_idx then
                within = p - (target_idx - 1)
            else
                within = 0
            end
        end
        if target_idx ~= id.chapter_idx then
            local started = require("ui.reader.session").gotoChapter(target_idx, { within = within })
            if not started then
                return
            end
            if show_msg then
                UIManager:show(InfoMessage:new{
                    text = T(_("已跳转到约 %1%"), string.format("%.1f", pct * 100)),
                    timeout = 2,
                })
            end
            return
        end
        applyFractionToDoc(ui, within)
    else
        applyFractionToDoc(ui, pct)
    end
    if show_msg then
        UIManager:show(InfoMessage:new{
            text = T(_("已跳转到约 %1%"), string.format("%.1f", pct * 100)),
            timeout = 2,
        })
    end
end

--- 本地与云端进度不一致：询问用户用哪个（本次阅读会话只问一次）。
--- 选云端 → 跳转；选本地 → 把本地推上去收敛，避免下次再问。
---@param ui table
---@param id BookIdentity
---@param pos ProgressPosition
---@param pct number
---@param local_frac number
local function askProgressConflict(id, pos, pct, local_frac)
    local key = id.source_id .. "\31" .. id.stable_id
    if asked_conflicts[key] then return end
    asked_conflicts[key] = true
    local ConfirmBox = require("ui/widget/confirmbox")
    local remote_label = T(_("云端 %1%"), string.format("%.1f", pct * 100))
    local local_label = T(_("本地 %1%"), string.format("%.1f", local_frac * 100))
    UIManager:show(ConfirmBox:new{
        text = T(_("本地与云端进度不一致（%1 / %2），跳转到哪个？"), local_label, remote_label),
        ok_text = remote_label,
        cancel_text = local_label,
        ok_callback = function()
            local Session = require("ui.reader.session")
            local current = Session.current()
            if current and Session.isCurrent(id) then
                applyRemotePos(current.ui, current.identity, pos, pct, true)
            end
        end,
        cancel_callback = function()
            local Session = require("ui.reader.session")
            local current = Session.current()
            if current and Session.isCurrent(id) then
                Progress.save(current, function(ok)
                    if ok and id.source and id.source.syncProgressAsync then
                        id.source:syncProgressAsync({ identity = id }, function() end)
                    end
                end)
            end
        end,
    })
end

--- 从数据源拉取进度并应用到当前文档
---@param snapshot ReaderSessionSnapshot
function Progress.pull(snapshot)
    local id = snapshot and snapshot.identity
    if not id then return end
    local source = id.source
    if not source or not source.syncProgressAsync then
        return
    end
    source:syncProgressAsync({ identity = id }, function(result, err)
            -- 校验当前文档身份：若用户已切换到其他书，跳过进度应用
            local Session = require("ui.reader.session")
            if not Session.isCurrent(id) then
                logger.dbg("book.progress pull skip: document changed")
                return
            end
            if not result then
                UIManager:show(InfoMessage:new{ text = err or _("拉取失败") })
                return
            end
            if result.skipped then return end
            local pos = ProgressDB.get(id.source_id, id.stable_id)
            if not pos then return end
            local local_position = Session.position()
            if id.chapter_idx and Session.toc() then
                local local_idx = local_position and local_position.chapter_idx
                local remote_idx = pos.chapter_idx
                if local_idx and remote_idx and local_idx ~= remote_idx then
                    askProgressConflict(id, pos, pos.fraction, local_position.fraction)
                    return
                end
                local local_within = local_position and local_position.chapter_fraction or 0
                local remote_within = pos.chapter_fraction
                if remote_within == nil then
                    local count = #Session.toc()
                    if count > 0 then
                        local p = pos.fraction * count
                        local expect = math.floor(p) + 1
                        if expect == (remote_idx or local_idx) then
                            remote_within = p - (expect - 1)
                        else
                            remote_within = 0
                        end
                    else
                        remote_within = 0
                    end
                end
                if math.abs(local_within - remote_within) >= 0.01 then
                    askProgressConflict(id, pos, pos.fraction, local_position.fraction)
                end
                return
            end
            local local_frac = local_position and local_position.fraction or 0
            if math.abs(local_frac - pos.fraction) < 0.01 then
                return
            end
            askProgressConflict(id, pos, pos.fraction, local_frac)
        end)
end

function Progress.clearConflicts()
    asked_conflicts = {}
end

return Progress
