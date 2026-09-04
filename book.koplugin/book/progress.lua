--[[--
阅读进度：输出 ProgressPosition，经 Source 拉/推。
本地进度写入 pending_progress；上传仅处理未同步行。

@module koplugin.book.book.progress
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("utils.log")
local ProgressDB = require("db.progress")
local ProgressPosition = require("types.book_progress")
local Position = require("book.progress.position")
local Text = require("utils.text")
local _ = require("gettext")

local Progress = {}
local asked_conflicts = {}
local last_revision = 0

--- 生成单调递增的进度修订号（同一进程内不会重复）。
--- 秒级时间戳在同一秒内多次写入会撞号，而修订号是 pending_progress 判定新旧的
--- 依据，必须严格递增。
---@return integer
local function nextRevision()
    last_revision = math.max(os.time(), last_revision + 1)
    return last_revision
end

--- 按位置填充翻译串里的 %1、%2… 占位符（每个占位符只替换首次出现）。
---@param fmt string 含 %N 占位符的模板
---@param ... any 依次替换 %1、%2…
---@return string
local function T(fmt, ...)
    local s = tostring(fmt)
    for i = 1, select("#", ...) do
        s = s:gsub("%%" .. i, tostring(select(i, ...)), 1)
    end
    return s
end
--- 从阅读快照取得全书阅读比例 0..1（按章源会合成）。
---@param snapshot ReaderSessionSnapshot
---@return number
function Progress.fraction(snapshot)
    if not snapshot then return 0 end
    local toc = require("ui.reader.session.toc").list(snapshot)
    return Position.fraction(snapshot, toc)
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
    local Session = require("ui.reader.session")
    local Toc = require("ui.reader.session.toc")
    local position = Position.position(snapshot, Toc.list(snapshot), Session.chapterTitle(snapshot))
    if position.chapter_idx then
        position.chapter_fraction = Toc.chapterFraction(snapshot) or position.chapter_fraction
    end
    return position
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
    local ok = ProgressDB.markSynced(source_id, stable_id, revision)
    if not ok then logger.warn("book.progress confirm failed", stable_id) end
    done(ok)
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
    local previous = ProgressDB.get(id.source_id, id.stable_id)
    local previous_extra = previous and previous.extra
    local previous_idx = previous_extra and tonumber(previous_extra.chapter_idx)
    if previous_idx and previous_idx == tonumber(pos.chapter_idx) then
        -- position 只包含通用阅读坐标；同章时保留源侧不透明 extra，
        -- 避免保存本地进度时丢失远端桥接坐标。
        pos.extra = previous_extra
    end
    pos.updated_at = nextRevision()
    local ok = ProgressDB.upsert(id.source_id, id.stable_id, pos)
    if not ok then logger.warn("book.progress save failed", id.stable_id) end
    if cb then cb(ok) end
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
    local target = opts.identity and opts.identity.stable_id or "all"
    local can_pull = source and type(source.getProgressAsync) == "function"
    local can_push = source and type(source.putProgressAsync) == "function"
    local cancelled, current_job = false, nil
    local result = { pulled = 0, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    logger.dbg("book.progress sync start", source and source.id or "none", target,
        opts.dirty_only and "dirty_only" or "full")
    --- 终结整次同步并回调；已取消时静默丢弃。
    ---@param value SyncResult|nil nil 表示失败
    ---@param err any
    local function finish(value, err)
        if cancelled then return end
        if value then
            logger.dbg("book.progress sync done", source and source.id or "none", target,
                "pulled", value.pulled or 0, "pushed", value.pushed or 0,
                "conflicts", value.conflicts or 0)
        else
            logger.warn("book.progress sync failed", source and source.id or "none", target, err)
        end
        if cb then cb(value, err) end
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
    ---@param source_id string
    ---@param stable_id string|nil 空串与 nil 直接忽略
    ---@param chapter_idx integer|nil nil 表示整本书
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
        for _, stable_id in ipairs(require("db.book").libraryStableIdsBySource(source.id)) do
            add(source.id, stable_id)
        end
    end
    if not opts.identity then
        for _, row in ipairs(ProgressDB.unsynced(source.id)) do
            add(source.id, row.stable_id, row.chapter_idx)
        end
    end

    local index = 1
    --- 处理队列里的下一个身份：本地脏行先推、确认后再拉远端；队列空即 finish。
    --- 串行推进（每步在回调里递归），保证同一本书不会同时推和拉。
    local function nextIdentity()
        if cancelled then return end
        local identity = identities[index]
        index = index + 1
        if not identity then finish(result); return end

        --- 拉当前身份的远端进度落库，再推进到下一个身份。
        --- dirty_only 模式或源不支持拉取时直接跳过。
        local function pullRemote()
            if opts.dirty_only or not can_pull then nextIdentity(); return end
            current_job = source:getProgressAsync(identity, function(pos, err)
                current_job = nil
                if cancelled then return end
                if not pos then finish(nil, err or "progress pull failed"); return end
                if ProgressDB.upsertRemote(source.id, identity.stable_id, pos) then
                    result.pulled = result.pulled + 1
                    nextIdentity()
                else
                    finish(nil, "failed to save remote progress")
                end
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

--- 把选定的进度应用到当前文档（按章书跳章，整本书跳比例）。
--- 冲突弹窗两个方向都用它：选云端跳云端位置，选本地跳本地那份记录。
--- 调用前提：已确认 pos 与当前位置不一致且文档身份未变。
--- 只有活动的按章会话才允许切章；冷打开的章节文件按单文档处理。
---@param ui table
---@param id BookIdentity
---@param pos ProgressPosition
---@param pct number clamp 后的全书比例
---@param show_msg boolean|nil
local function applyChosenPos(ui, id, pos, pct, show_msg)
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
            -- 置位挪进回调：点空白关闭弹窗时两个回调都不跑，
            -- 在 show 之前置位会让本次会话再也不问，脏本地进度既不推也不采纳。
            asked_conflicts[key] = true
            local Session = require("ui.reader.session")
            local current = Session.current()
            if not current or not isSameBook(id) then
                return
            end
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
            if not ProgressDB.adoptRemote(id.source_id, id.stable_id, remote) then
                logger.warn("book.progress adopt remote failed", id.stable_id)
                return
            end
            local live = Session.current()
            if live and isSameBook(id) then
                applyChosenPos(live.ui, live.identity, remote_pos, remote_pos.fraction, true)
            end
        end,
        cancel_callback = function()
            asked_conflicts[key] = true
            local Session = require("ui.reader.session")
            if not Session.current() or not isSameBook(id) then
                return
            end
            -- 落回弹窗上展示的那份本地进度，不能重新采样实时位置：冷打开的落点
            -- 可能比本地记录更靠前，那会把「保留本地」变成覆盖本地。
            local adopt = {}
            for k, v in pairs(local_pos) do adopt[k] = v end
            adopt.updated_at = nextRevision()
            if not ProgressDB.upsert(id.source_id, id.stable_id, adopt) then
                logger.warn("book.progress adopt local failed", id.stable_id)
                return
            end
            local live = Session.current()
            if live and isSameBook(id) then
                applyChosenPos(live.ui, live.identity, adopt, adopt.fraction, false)
            end
            if id.source and id.source.syncProgressAsync then
                id.source:syncProgressAsync({ identity = id }, function() end)
            end
        end,
    })
end

--- 开书后拉远端进度并与当前阅读位置对比；冲突时弹窗，一致则直接收敛。
--- 必须先拉后比：syncProgressAsync 会先推脏本地，会把冲突静默抹平。
---@param snapshot ReaderSessionSnapshot
function Progress.pull(snapshot)
    local id = snapshot and snapshot.identity
    if not id then return end
    local source = id.source
    if not source or type(source.getProgressAsync) ~= "function" then
        return
    end
    logger.dbg("book.progress reader pull start", id.source_id, id.stable_id,
        id.chapter_idx or "book")
    source:getProgressAsync(id, function(remote_pos, err)
        if not isSameBook(id) then
            logger.dbg("book.progress pull skip: document changed")
            return
        end
        if not remote_pos then
            logger.warn("book.progress reader pull failed", id.source_id, id.stable_id, err)
            UIManager:show(InfoMessage:new{ text = err or _("拉取失败") })
            return
        end
        local local_position = localProgressForPull(id, snapshot)
        if progressDiffers(local_position, remote_pos, id, snapshot) then
            logger.dbg("book.progress reader pull conflict", id.source_id, id.stable_id)
            askProgressConflict(id, snapshot, local_position, remote_pos)
            return
        end
        local row = ProgressDB.get(id.source_id, id.stable_id)
        if row and row.sync_status == 0 then
            -- 本地脏版本与云端基本一致时只推不拉；上面已经拿到了最新远端，
            -- 再跑完整同步只会产生第二次相同的 getProgress。
            if source.syncProgressAsync then
                source:syncProgressAsync({ identity = id, dirty_only = true }, function() end)
            end
        elseif not ProgressDB.upsertRemote(id.source_id, id.stable_id, remote_pos) then
            logger.warn("book.progress save remote failed", id.stable_id)
            return
        end
        logger.dbg("book.progress reader pull done", id.source_id, id.stable_id, "matched")
    end)
end

--- 清空「已问过进度冲突」的记忆，下次开书会重新弹 ConfirmBox。
--- 由 Session.onCloseDocument 在真正关书（非切章）时调用。
function Progress.clearConflicts()
    asked_conflicts = {}
end

return Progress
