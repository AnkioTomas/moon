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
local Text = require("utils.text")
local _ = require("gettext")

local Progress = {}
local asked_conflicts = {}
local last_revision = 0

local function nextRevision()
    last_revision = math.max(os.time(), last_revision + 1)
    return last_revision
end

local function T(fmt, ...)
    local s = tostring(fmt)
    for i = 1, select("#", ...) do
        s = s:gsub("%%" .. i, tostring(select(i, ...)), 1)
    end
    return s
end
--- 把文档内比例合成为全书比例。
---@param doc_frac number
---@param id BookIdentity|nil
---@param toc BookChapter[]|nil
---@param reading_idx number|nil
---@return number
local function wholeFraction(doc_frac, id, toc, reading_idx)
    local idx = id and id.chapter_idx or reading_idx
    if not idx then
        return doc_frac
    end
    local count = toc and #toc
    idx = tonumber(idx) or 1
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
    local SessionToc = require("ui.reader.session.toc")
    local toc = SessionToc.list(snapshot)
    return wholeFraction(doc_frac, identity, toc, snapshot.reading_chapter_idx)
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
    local Toc = require("ui.reader.session.toc")
    local chapter_idx = id.chapter_idx or snapshot and snapshot.reading_chapter_idx
    local chapter_frac
    if chapter_idx then
        chapter_frac = Toc.chapterFraction(snapshot) or doc_frac
    end
    local ui = snapshot and snapshot.ui
    return {
        fraction = Progress.fraction(snapshot),
        chapter_idx = chapter_idx,
        chapter_title = Session.chapterTitle(snapshot),
        chapter_fraction = chapter_frac,
        page = page and page > 0 and math.floor(page) or nil,
        total_pages = total_pages and total_pages > 0 and math.floor(total_pages) or nil,
        -- rolling 文档的精确定位；paging 文档没有 xpointer，靠 page 恢复。
        locator = ui and ui.rolling and ui.rolling.xpointer or nil,
    }
end

--- 把跳转结果落到 sidecar，让原生阅读器下次开书就在这个位置。
---
--- 只写打开中的 ``ui.doc_settings``：``DocSettings:open`` 每次都从磁盘新建实例，
--- 另开一份写盘会在关书 flush 时被 ReaderUI 那份整体覆盖。
---@param ui table
---@param pct number 已 clamp 的文档内比例
local function saveDocSettings(ui, pct)
    local settings = ui.doc_settings
    if not settings then return end
    settings:saveSetting("percent_finished", pct)
    if ui.rolling and ui.rolling.xpointer then
        settings:saveSetting("last_xpointer", ui.rolling.xpointer)
    elseif ui.paging and ui.view then
        settings:saveSetting("last_page", ui.view.state and ui.view.state.page)
    end
    settings:flush()
end

--- 精确定位：rolling 文档的 XPointer。跳转成功返回 true。
---
--- 必须先验 ``isXPointerInDocument``：换源、换版本或章节文件变了之后，
--- 旧 XPointer 会把读者扔到文档里一个毫不相干的位置。
---@param ui table
---@param locator string|nil
---@return boolean
local function gotoLocator(ui, locator)
    if type(locator) ~= "string" or locator == "" then return false end
    local doc = ui.document
    if not doc or not doc.isXPointerInDocument then return false end
    local ok, inside = pcall(doc.isXPointerInDocument, doc, locator)
    if not ok or not inside then return false end
    if ui.rolling then
        ui.rolling:onGotoXPointer(locator)
    elseif ui.link then
        ui.link:onGotoXPointer(locator)
    else
        return false
    end
    return true
end

--- 精确定位：固定版式的页码。跳转成功返回 true。
---
--- 只有总页数与记录时一致才认页码：重新排版后同一个页码是另一个位置。
---@param ui table
---@param pos ProgressPosition|nil
---@return boolean
local function gotoPage(ui, pos)
    local page = pos and tonumber(pos.page)
    local recorded_total = pos and tonumber(pos.total_pages)
    local doc = ui.document
    if not page or not recorded_total or not doc or not doc.getPageCount then return false end
    local total = doc:getPageCount()
    if not total or total ~= recorded_total or page < 1 or page > total then return false end
    ui:handleEvent(Event:new("GotoPage", math.floor(page)))
    return true
end

--- 把一个位置应用到当前文档，并同步落 sidecar。
---
--- 按精度降级：XPointer > 页码 > 比例。比例会随字号、边距、字体变化漂移，
--- 同一本书在两台设备上算出的比例根本对不齐，所以它只是最后的兜底手段。
---@param ui table
---@param pos ProgressPosition|nil 位置；缺精确坐标时退回 pct
---@param pct number 文档内比例，最后手段
local function applyPosition(ui, pos, pct)
    pct = ProgressPosition.clampFraction(pct)
    if not gotoLocator(ui, pos and pos.locator) and not gotoPage(ui, pos) then
        local doc = ui.document
        if doc and doc.getXPointerFromProportion then
            local xptr = doc:getXPointerFromProportion(pct)
            if xptr and ui.rolling then
                ui.rolling:onGotoXPointer(xptr)
            elseif xptr and ui.link then
                ui.link:onGotoXPointer(xptr)
            end
        elseif doc and doc.getPageCount then
            local total = doc:getPageCount() or 1
            local page = math.max(1, math.min(total, math.floor(pct * total + 0.5)))
            ui:handleEvent(Event:new("GotoPage", page))
        else
            return
        end
    end
    saveDocSettings(ui, pct)
end

--- 冷打开：pending 章序号与当前身份一致时恢复章内位置。
--- 同章才敢用 locator——它是章节文件内的坐标，跨章无意义。
---@param snapshot ReaderSessionSnapshot
function Progress.applyLocalPending(snapshot)
    local id = snapshot and snapshot.identity
    if not id or not id.chapter_idx or not snapshot.ui then return end
    local row = ProgressDB.get(id.source_id, id.stable_id)
    if not row or tonumber(row.chapter_idx) ~= tonumber(id.chapter_idx) then return end
    if row.locator == nil and row.chapter_fraction == nil then return end
    applyPosition(snapshot.ui, row, row.chapter_fraction or 0)
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
        extra = row.extra,
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
                if ok ~= true then
                    if opts.dirty_only then
                        result.conflicts = result.conflicts + 1
                        nextIdentity()
                        return
                    end
                    finish(nil, err or "progress push failed")
                    return
                end
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

--- 异步进度回调是否仍对同一本书有效（不比 chapter_idx，避免切章后丢弃拉取结果）。
---@param id BookIdentity|nil
---@return boolean
local function isSameBook(id)
    local current = require("ui.reader.session").current()
    local cur = current and current.identity
    return cur ~= nil and id ~= nil
        and cur.source_id == id.source_id
        and cur.stable_id == id.stable_id
end

--- 当前会话可用的章节目录（优先阅读快照，不依赖 Store.toc 是否已落库）。
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot|nil
---@return BookChapter[]|nil
local function chapterToc(id, snapshot)
    if not id or not id.source or id.source.type ~= "chapter" then
        return nil
    end
    local Session = require("ui.reader.session")
    local snap = snapshot or Session.current()
    if not snap or not snap.identity then
        return nil
    end
    if snap.identity.source_id ~= id.source_id or snap.identity.stable_id ~= id.stable_id then
        return nil
    end
    local toc = require("ui.reader.session.toc").list(snap)
    if type(toc) == "table" and #toc > 0 then
        return toc
    end
    return nil
end

--- 开书对比用的本地进度：pending_progress 为准，同章时章内比例优先于章首快照。
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot
---@return ProgressPosition
local function localProgressForPull(id, snapshot)
    local live = Progress.position(snapshot)
    local row = ProgressDB.get(id.source_id, id.stable_id)
    if not row then
        return live
    end
    local pos = rowPosition(row)
    if pos.chapter_idx and live.chapter_idx
        and tonumber(pos.chapter_idx) == tonumber(live.chapter_idx) then
        if pos.chapter_fraction == nil and live.chapter_fraction ~= nil then
            pos.chapter_fraction = live.chapter_fraction
        end
    end
    return pos
end

--- 冲突弹窗用的可读进度标签（按章书优先章序号，整书优先页码，最后才用全书比例）。
---@param pos ProgressPosition|nil
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot|nil
---@return string
local function conflictLabel(pos, id, snapshot)
    pos = pos or {}
    local toc = chapterToc(id, snapshot)
    if toc then
        local count = #toc
        local idx = tonumber(pos.chapter_idx)
        if not idx and count > 0 and pos.fraction then
            idx = math.floor(pos.fraction * count) + 1
        end
        if idx then
            local title = pos.chapter_title
            if (type(title) ~= "string" or title == "") and toc[idx] then
                title = toc[idx].title or toc[idx].name
            end
            if type(title) == "string" then
                title = title:match("^%s*(.-)%s*$") or ""
                local clipped = Text.truncateUtf8(title, 48)
                if clipped ~= title then
                    title = clipped .. "…"
                else
                    title = clipped
                end
            else
                title = ""
            end
            local within = pos.chapter_fraction
            if within == nil and idx and count > 0 and pos.fraction then
                local p = pos.fraction * count
                local expect = math.floor(p) + 1
                if expect == idx then
                    within = p - (idx - 1)
                end
            end
            local within_pct = within and math.floor(within * 100 + 0.5) or nil
            if title ~= "" and within_pct and within_pct > 0 then
                return T(_("第 %1 章 · %2 · 章内 %3%"), idx, title, within_pct)
            end
            if title ~= "" then
                return T(_("第 %1 章 · %2"), idx, title)
            end
            if within_pct and within_pct > 0 then
                return T(_("第 %1 章 · 章内 %2%"), idx, within_pct)
            end
            return T(_("第 %1 章"), idx)
        end
    end
    local page = tonumber(pos.page)
    local total = tonumber(pos.total_pages)
    if page and total and total > 0 then
        return T(_("第 %1 / %2 页"), math.floor(page), math.floor(total))
    end
    return T(_("%1%"), string.format("%.1f", (tonumber(pos.fraction) or 0) * 100))
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
    local toc = chapterToc(id)
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
                    text = T(_("已跳转到 %1"), conflictLabel(pos, id)),
                    timeout = 2,
                })
            end
            return
        end
        -- 已在目标章内：远端 locator 是这一章的坐标，可以直接用。
        applyPosition(ui, pos, within)
    else
        applyPosition(ui, pos, pct)
    end
    if show_msg then
        UIManager:show(InfoMessage:new{
            text = T(_("已跳转到 %1"), conflictLabel(pos, id)),
            timeout = 2,
        })
    end
end

--- 按章模式：从远端进度推算章内比例。
---@param pos ProgressPosition
---@param chapter_idx integer|nil
---@param toc_count integer
---@return number
local function remoteWithin(pos, chapter_idx, toc_count)
    local within = pos.chapter_fraction
    if within ~= nil then
        return within
    end
    if toc_count <= 0 then
        return 0
    end
    local remote_idx = pos.chapter_idx or chapter_idx
    local p = pos.fraction * toc_count
    local expect = math.floor(p) + 1
    if expect == remote_idx then
        return p - (expect - 1)
    end
    return 0
end

--- 当前阅读位置与 freshly pulled 远端进度是否冲突（≥1%）。
---@param local_pos ProgressPosition|nil
---@param remote_pos ProgressPosition
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot
---@return boolean
local function progressDiffers(local_pos, remote_pos, id, snapshot)
    -- 精确坐标一致就是同一个位置，不必再拿会漂移的比例去比。
    local here = local_pos and local_pos.locator
    if here and here == remote_pos.locator then
        return false
    end
    local toc = chapterToc(id, snapshot)
    if toc then
        local count = #toc
        local local_idx = local_pos and tonumber(local_pos.chapter_idx)
        local remote_idx = remote_pos.chapter_idx and tonumber(remote_pos.chapter_idx)
        if not remote_idx then
            remote_idx = math.floor(remote_pos.fraction * count) + 1
        end
        if local_idx and remote_idx and local_idx ~= remote_idx then
            return true
        end
        if local_idx and remote_idx and local_idx == remote_idx then
            local local_within = local_pos and local_pos.chapter_fraction or 0
            local remote_w = remoteWithin(remote_pos, remote_idx, count)
            return math.abs(local_within - remote_w) >= 0.01
        end
    end
    local local_frac = local_pos and local_pos.fraction or 0
    return math.abs(local_frac - remote_pos.fraction) >= 0.01
end

--- 本地与云端进度不一致：询问用户用哪个（本次阅读会话只问一次）。
--- 选云端 → 跳转；选本地 → 把本地推上去收敛，避免下次再问。
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot
---@param local_pos ProgressPosition
---@param remote_pos ProgressPosition
local function askProgressConflict(id, snapshot, local_pos, remote_pos)
    local key = id.source_id .. "\31" .. id.stable_id
    if asked_conflicts[key] then return end
    asked_conflicts[key] = true
    local ConfirmBox = require("ui/widget/confirmbox")
    local local_desc = conflictLabel(local_pos, id, snapshot)
    local remote_desc = conflictLabel(remote_pos, id, snapshot)
    local local_btn = T(_("本地：%1"), local_desc)
    local remote_btn = T(_("云端：%1"), remote_desc)
    UIManager:show(ConfirmBox:new{
        text = T(_("本地与云端进度不一致（%1 / %2），跳转到哪个？"), local_desc, remote_desc),
        ok_text = remote_btn,
        cancel_text = local_btn,
        ok_callback = function()
            local Session = require("ui.reader.session")
            local current = Session.current()
            if not current or not isSameBook(id) then
                return
            end
            DbQueue.run(function()
                local remote = {
                    fraction = remote_pos.fraction,
                    chapter_idx = remote_pos.chapter_idx,
                    chapter_title = remote_pos.chapter_title,
                    chapter_fraction = remote_pos.chapter_fraction,
                    page = remote_pos.page,
                    total_pages = remote_pos.total_pages,
                    locator = remote_pos.locator,
                    extra = remote_pos.extra,
                    updated_at = os.time(),
                }
                assert(ProgressDB.adoptRemote(id.source_id, id.stable_id, remote),
                    "failed to save remote progress")
            end, {
                on_done = function()
                    local live = Session.current()
                    if live and isSameBook(id) then
                        applyRemotePos(live.ui, live.identity, remote_pos, remote_pos.fraction, true)
                    end
                end,
            })
        end,
        cancel_callback = function()
            local Session = require("ui.reader.session")
            local current = Session.current()
            if current and isSameBook(id) then
                Progress.save(current, function(ok)
                    if ok and id.source and id.source.syncProgressAsync then
                        id.source:syncProgressAsync({ identity = id }, function() end)
                    end
                end)
            end
        end,
    })
end

--- 开书后拉远端进度并与当前阅读位置对比；冲突时弹窗，一致则后台 sync 收敛。
--- 必须先拉后比：syncProgressAsync 会先推脏本地，会把冲突静默抹平。
---@param snapshot ReaderSessionSnapshot
function Progress.pull(snapshot)
    local id = snapshot and snapshot.identity
    if not id then return end
    local source = id.source
    if not source or type(source.getProgressAsync) ~= "function" then
        return
    end
    source:getProgressAsync(id, function(remote_pos, err)
        if not isSameBook(id) then
            logger.dbg("book.progress pull skip: document changed")
            return
        end
        if not remote_pos then
            UIManager:show(InfoMessage:new{ text = err or _("拉取失败") })
            return
        end
        local local_position = localProgressForPull(id, snapshot)
        if progressDiffers(local_position, remote_pos, id, snapshot) then
            askProgressConflict(id, snapshot, local_position, remote_pos)
            return
        end
        if source.syncProgressAsync then
            source:syncProgressAsync({ identity = id }, function() end)
        end
    end)
end

function Progress.clearConflicts()
    asked_conflicts = {}
end

return Progress
