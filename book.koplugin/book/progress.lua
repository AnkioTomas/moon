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

--- 当前 ProgressPosition；位置完全来自 ReaderSession 快照。
---@param snapshot ReaderSessionSnapshot
---@return ProgressPosition
function Progress.position(snapshot)
    local id = snapshot and snapshot.identity or {}
    local doc_frac = snapshot and tonumber(snapshot.doc_fraction) or 0
    return {
        fraction = Progress.fraction(snapshot),
        chapter_idx = id.chapter_idx,
        chapter_fraction = id.chapter_idx and doc_frac or nil,
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
    pos.updated_at = os.time()
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

--- 上传数据库中所有未同步进度。网络失败由源回调 false，进度行保留。
---@param _ui table|nil 保留入口签名；进度数据完全来自数据库
function Progress.push(_ui)
    local sources = {}
    local Registry = require("source.registry")
    for _idx, row in ipairs(ProgressDB.unsynced()) do
        local source = sources[row.source_id]
        if source == nil then
            local resolved, err = Registry.resolve(row.source_id)
            source = resolved or false
            sources[row.source_id] = source
            if not source and err then
                logger.warn("book.progress source unavailable", row.source_id, err)
            end
        end
        if source and source.putProgressAsync then
            local identity = { source_id = row.source_id, stable_id = row.stable_id }
            local pos = {
                fraction = row.fraction,
                chapter_idx = row.chapter_idx,
                chapter_fraction = row.chapter_fraction,
                locator = row.locator,
            }
            source:putProgressAsync(identity, pos, function(res, err)
                if res == true then
                    confirm(row.source_id, row.stable_id, row.updated_at, function() end)
                else
                    logger.warn("book.progress push failed", row.stable_id, err)
                end
            end)
        end
    end
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
        local within = pos.chapter_fraction or pct
        if not target_idx then
            local p = pct * count
            target_idx = math.max(1, math.min(count, math.floor(p) + 1))
            within = p - (target_idx - 1)
        elseif not pos.chapter_fraction then
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
        end,
    })
end

--- 从数据源拉取进度并应用到当前文档
---@param snapshot ReaderSessionSnapshot
function Progress.pull(snapshot)
    local id = snapshot and snapshot.identity
    if not id then return end
    local source = id.source
    if not source or not source.getProgressAsync then
        return
    end
    Progress.save(snapshot, function(ok)
        if not ok then
            return
        end
        source:getProgressAsync(id, function(pos, err)
            -- 校验当前文档身份：若用户已切换到其他书，跳过进度应用
            local Session = require("ui.reader.session")
            if not Session.isCurrent(id) then
                logger.dbg("book.progress pull skip: document changed")
                return
            end
            if not pos then
                UIManager:show(InfoMessage:new{ text = err or _("拉取失败") })
                return
            end
            local local_position = Session.position()
            local local_frac = local_position and local_position.fraction or 0
            if math.abs(local_frac - pos.fraction) < 0.01 then
                return
            end
            askProgressConflict(id, pos, pos.fraction, local_frac)
        end)
    end)
end

return Progress
