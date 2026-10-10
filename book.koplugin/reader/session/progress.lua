--[[--
阅读期进度：从会话快照采样、落本地、开书拉云端并处理冲突、把选定位置应用到文档。
数据与上行同步在 ``book.progress``；这里只做阅读器侧的事。

@module koplugin.book.reader.session.progress
--]]

local logger = require("utils.log")
local ProgressDB = require("book.progress_db")
local Progress = require("book.progress")
local Position = require("reader.session.position")
local Text = require("utils.text")
local T = require("ffi/util").template
local _ = require("gettext")

local ReaderProgress = {
    asked_conflicts = {},
}

--- 当前 ProgressPosition；位置完全来自 ReaderSession 快照。
---@param snapshot ReaderSessionSnapshot
---@return ProgressPosition
function ReaderProgress.position(snapshot)
    local Session = require("reader.session")
    local Toc = require("reader.session.toc")
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
    local Event = require("ui/event")
    ui:handleEvent(Event:new("GotoPage", math.floor(page)))
    return true
end

--- 按文档内比例跳转：流式文档走 XPointer，否则按页码。
---@param ui table
---@param pct number
function ReaderProgress.gotoFraction(ui, pct)
    pct = Progress.clampFraction(pct)
    local doc = ui.document
    local xptr = doc.getXPointerFromProportion and doc:getXPointerFromProportion(pct)
    if xptr and ui.rolling then
        ui.rolling:onGotoXPointer(xptr)
    elseif xptr and ui.link then
        ui.link:onGotoXPointer(xptr)
    else
        local total = doc:getPageCount() or 1
        local Event = require("ui/event")
        ui:handleEvent(Event:new("GotoPage", math.max(1, math.min(total, math.floor(pct * total + 0.5)))))
    end
end

--- 把一个位置应用到当前文档，并同步落 sidecar。
---
--- 按精度降级：XPointer > 页码 > 比例。比例会随字号、边距、字体变化漂移，
--- 同一本书在两台设备上算出的比例根本对不齐，所以它只是最后的兜底手段。
---@param ui table
---@param pos ProgressPosition|nil 位置；缺精确坐标时退回 pct
---@param pct number 文档内比例，最后手段
local function applyPosition(ui, pos, pct)
    pct = Progress.clampFraction(pct)
    if not gotoLocator(ui, pos and pos.locator) and not gotoPage(ui, pos) then
        ReaderProgress.gotoFraction(ui, pct)
    end
    saveDocSettings(ui, pct)
end

--- 冷打开：pending 章序号与当前身份一致时恢复章内位置。
--- 同章才敢用 locator——它是章节文件内的坐标，跨章无意义。
---@param snapshot ReaderSessionSnapshot
function ReaderProgress.applyLocalPending(snapshot)
    local id = snapshot and snapshot.identity
    if not id or not id.chapter_idx or not snapshot.ui then return end
    local row = ProgressDB.get(id.source_id, id.stable_id)
    if not row or tonumber(row.chapter_idx) ~= tonumber(id.chapter_idx) then return end
    if row.locator == nil and row.chapter_fraction == nil then return end
    applyPosition(snapshot.ui, row, row.chapter_fraction or 0)
end

--- 保存当前文档进度。写入完成前不发网络请求，避免同步旧快照。
---@param snapshot ReaderSessionSnapshot
---@param cb fun(ok: boolean)|nil
function ReaderProgress.save(snapshot, cb)
    local id = snapshot and snapshot.identity
    if not id or not id.source_id or not id.stable_id then
        if cb then cb(false) end
        return
    end
    local pos = ReaderProgress.position(snapshot)
    local previous = ProgressDB.get(id.source_id, id.stable_id)
    local previous_extra = previous and previous.extra
    local previous_idx = previous_extra and tonumber(previous_extra.chapter_idx)
    if previous_idx and previous_idx == tonumber(pos.chapter_idx) then
        -- position 只包含通用阅读坐标；同章时保留源侧不透明 extra，
        -- 避免保存本地进度时丢失远端桥接坐标。
        pos.extra = previous_extra
    end
    pos.updated_at = Progress.nextRevision()
    local ok = ProgressDB.upsert(id.source_id, id.stable_id, pos)
    if not ok then logger.warn("book.progress save failed", id.stable_id) end
    if cb then cb(ok) end
end

--- 异步进度回调是否仍对同一本书有效（不比 chapter_idx，避免切章后丢弃拉取结果）。
---@param id BookIdentity|nil
---@return boolean
local function isSameBook(id)
    local current = require("reader.session").current()
    local cur = current and current.identity
    return cur ~= nil and id ~= nil
        and cur.source_id == id.source_id
        and cur.stable_id == id.stable_id
end

--- 连续章节会话的目录；整书或目录为空时为 nil（调用方已确认是同一本书）。
---@param snapshot ReaderSessionSnapshot|nil 缺省当前会话
---@return BookChapter[]|nil
local function chapterToc(snapshot)
    local snap = snapshot or require("reader.session").current()
    local toc = snap and snap.chapter and snap.chapter.toc
    return toc and #toc > 0 and toc or nil
end

--- 开书对比用的本地进度：pending_progress 为准，同章时章内比例优先于章首快照。
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot
---@return ProgressPosition
local function localProgressForPull(id, snapshot)
    local live = ReaderProgress.position(snapshot)
    local row = ProgressDB.get(id.source_id, id.stable_id)
    if not row then
        return live
    end
    local pos = Progress.rowPosition(row)
    if pos.chapter_idx and live.chapter_idx
        and tonumber(pos.chapter_idx) == tonumber(live.chapter_idx) then
        if pos.chapter_fraction == nil and live.chapter_fraction ~= nil then
            pos.chapter_fraction = live.chapter_fraction
        end
    end
    return pos
end

--- 由全书比例推算第 idx 章的章内比例；比例落不到该章时返回 nil。
---@param fraction number
---@param count integer 目录章数（>0）
---@param idx integer
---@return number|nil
local function withinFromFraction(fraction, count, idx)
    local p = fraction * count
    if math.floor(p) + 1 == idx then
        return p - (idx - 1)
    end
end

--- 冲突弹窗用的可读进度标签（按章书优先章序号，整书优先页码，最后才用全书比例）。
---@param pos ProgressPosition|nil
---@param id BookIdentity
---@param snapshot ReaderSessionSnapshot|nil
---@return string
local function conflictLabel(pos, id, snapshot)
    pos = pos or {}
    local toc = chapterToc(snapshot)
    if toc then
        local count = #toc
        local idx = tonumber(pos.chapter_idx)
        if not idx and count > 0 and pos.fraction then
            idx = math.floor(pos.fraction * count) + 1
        end
        if idx then
            local title = pos.chapter_title
            if (type(title) ~= "string" or title == "") and toc[idx] then
                title = toc[idx].title
            end
            if type(title) == "string" then
                local trimmed = Text.trim(title)
                local clipped = Text.truncateUtf8(trimmed, 48)
                title = clipped ~= trimmed and clipped .. "…" or clipped
            else
                title = ""
            end
            local within = pos.chapter_fraction
            if within == nil and count > 0 and pos.fraction then
                within = withinFromFraction(pos.fraction, count, idx)
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
    local toc = chapterToc()
    if toc then
        local count = #toc
        local target_idx = tonumber(pos.chapter_idx)
        local within = pos.chapter_fraction
        if not target_idx then
            local p = pct * count
            target_idx = math.max(1, math.min(count, math.floor(p) + 1))
            if within == nil then
                within = p - (target_idx - 1)
            end
        elseif within == nil then
            within = withinFromFraction(pct, count, target_idx) or 0
        end
        if target_idx ~= id.chapter_idx then
            if not require("reader.session").gotoChapter(target_idx, { within = within }) then
                require("ui.themes.widgets.toast"):new{
                    text = T(_("跳转到 %1 失败"), conflictLabel(pos, id)),
                    timeout = 3,
                }:show()
                return
            end
        else
            -- 已在目标章内：远端 locator 是这一章的坐标，可以直接用。
            applyPosition(ui, pos, within)
        end
    else
        applyPosition(ui, pos, pct)
    end
    if show_msg then
        require("ui.themes.widgets.toast"):new{
            text = T(_("已跳转到 %1"), conflictLabel(pos, id)),
            timeout = 2,
        }:show()
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
    return withinFromFraction(pos.fraction, toc_count, pos.chapter_idx or chapter_idx) or 0
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
    local toc = chapterToc(snapshot)
    if toc then
        local count = #toc
        local local_idx = local_pos and tonumber(local_pos.chapter_idx)
        local remote_idx = tonumber(remote_pos.chapter_idx)
            or math.floor(remote_pos.fraction * count) + 1
        if local_idx then
            if local_idx ~= remote_idx then
                return true
            end
            local local_within = local_pos.chapter_fraction or 0
            return math.abs(local_within - remoteWithin(remote_pos, remote_idx, count)) >= 0.01
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
    if ReaderProgress.asked_conflicts[key] then return end
    -- 弹出即记：弹窗未答时再来一次 pull（换章 / 唤醒）不能叠第二个窗。
    ReaderProgress.asked_conflicts[key] = true
    local local_desc = conflictLabel(local_pos, id, snapshot)
    local remote_desc = conflictLabel(remote_pos, id, snapshot)
    local local_btn = T(_("本地：%1"), local_desc)
    local remote_btn = T(_("云端：%1"), remote_desc)
    require("ui.themes.widgets.confirm"):new{
        text = T(_("本地与云端进度不一致（%1 / %2），跳转到哪个？"), local_desc, remote_desc),
        ok_text = remote_btn,
        cancel_text = local_btn,
        -- 两个按钮都是选择：主题 Confirm 点空白 / 返回键等同「取消」= 选本地并上推，必须关掉。
        dismissable = false,
        ok_callback = function()
            local Session = require("reader.session")
            local current = Session.current()
            if not current or not isSameBook(id) then
                return
            end
            local remote = Progress.rowPosition(remote_pos)
            remote.updated_at = os.time()
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
            local Session = require("reader.session")
            if not Session.current() or not isSameBook(id) then
                return
            end
            -- 落回弹窗上展示的那份本地进度，不能重新采样实时位置：冷打开的落点
            -- 可能比本地记录更靠前，那会把「保留本地」变成覆盖本地。
            local adopt = {}
            for k, v in pairs(local_pos) do adopt[k] = v end
            adopt.updated_at = Progress.nextRevision()
            if not ProgressDB.upsert(id.source_id, id.stable_id, adopt) then
                logger.warn("book.progress adopt local failed", id.stable_id)
                return
            end
            local live = Session.current()
            if live and isSameBook(id) then
                applyChosenPos(live.ui, live.identity, adopt, adopt.fraction, false)
            end
            if id.source and id.source.syncProgressAsync then
                id.source:syncProgressAsync({ identity = id, dirty_only = true }, function() end)
            end
        end,
    }:show()
end

--- 开书后拉远端进度并与当前阅读位置对比；冲突时弹窗，一致则直接收敛。
--- syncProgressAsync 只推不拉；本函数是进度 pull 的唯一入口。
---@param snapshot ReaderSessionSnapshot
function ReaderProgress.pull(snapshot)
    local id = snapshot and snapshot.identity
    if not id then return end
    local source = id.source
    if not source or type(source.getProgressAsync) ~= "function" then
        return
    end
    logger.dbg("book.progress reader pull start", id.source_id, id.stable_id,
        id.chapter_idx or "book")
    source:getProgressAsync(id, function(remote_pos, err, meta)
        if not isSameBook(id) then
            logger.dbg("book.progress pull skip: document changed")
            return
        end
        if type(meta) == "table" and meta.empty then
            logger.dbg("book.progress reader pull empty", id.source_id, id.stable_id)
            return
        end
        if not remote_pos then
            -- 离线开缓存书是正常路径；拉不到云端进度只记日志，不能打断阅读。
            logger.warn("book.progress reader pull failed", id.source_id, id.stable_id, err)
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
function ReaderProgress.clearConflicts()
    ReaderProgress.asked_conflicts = {}
end

return ReaderProgress
