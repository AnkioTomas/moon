--[[--
阅读进度：输出 ProgressPosition，经 Source 拉/推。
离线/失败写入 pending_progress，上线后 flush。

@module koplugin.book.book.progress
--]]

local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local Store = require("book.store")
local ProgressDB = require("utils.db.progress")
local DbQueue = require("utils.db.queue")
local BookRef = require("types.book").BookRef
local ProgressPosition = require("types.book_progress")
local _ = require("gettext")
local T = require("ffi/util").template

local Progress = {}

--- 当前文档身份 { ref, chapter_idx? }
---@param ui table
---@return { ref: BookRef, chapter_idx: number|nil }|nil
function Progress.identityFor(ui)
    if not ui or not ui.document or not ui.document.file then
        return nil
    end
    return Store.identityFor(ui.document.file)
end

--- 当前打开文档内的阅读比例 0..1
---@param ui table
---@return number
function Progress.docFraction(ui)
    if not ui or not ui.document then
        return 0
    end
    local doc = ui.document
    if doc.getXPointer and doc.getProportionFromXPointer then
        local ok, p = pcall(function()
            return doc:getProportionFromXPointer(doc:getXPointer())
        end)
        if ok and type(p) == "number" then
            return math.max(0, math.min(1, p))
        end
    end
    if ui.getCurrentPage and doc.getPageCount then
        local page = ui:getCurrentPage() or 1
        local total = doc.getPageCount and doc:getPageCount() or 1
        if total > 0 then
            return math.max(0, math.min(1, page / total))
        end
    end
    return 0
end

--- 全书阅读比例 0..1（按章源会合成）
---@param ui table
---@return number
function Progress.fraction(ui)
    local doc_frac = Progress.docFraction(ui)
    local id = Progress.identityFor(ui)
    if not id or not id.chapter_idx then
        return doc_frac
    end
    local Chapter = require("chapters.init")
    local count = Chapter.chapterCount()
    local idx = tonumber(id.chapter_idx) or 1
    if not count or count <= 0 then
        return doc_frac
    end
    return math.max(0, math.min(1, ((idx - 1) + doc_frac) / count))
end

--- 当前 ProgressPosition
---@param ui table
---@return ProgressPosition|nil
function Progress.position(ui)
    local id = Progress.identityFor(ui)
    if not id or not id.ref then
        return nil
    end
    return {
        fraction = Progress.fraction(ui),
        chapter_idx = id.chapter_idx,
        chapter_fraction = id.chapter_idx and Progress.docFraction(ui) or nil,
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

--- 进度入队待上传（异步，fire-and-forget）
---@param ref BookRef
---@param pos ProgressPosition
local function enqueue(ref, pos)
    if not ref or not pos then
        return
    end
    local source_id = ref.source_id
    local stable_id = ref.stable_id
    local fraction = pos.fraction
    local chapter_idx = pos.chapter_idx
    local chapter_fraction = pos.chapter_fraction
    local locator = pos.locator
    local updated_at = pos.updated_at or os.time()
    DbQueue.run(function()
        ProgressDB.upsert(source_id, stable_id, {
            fraction = fraction,
            chapter_idx = chapter_idx,
            chapter_fraction = chapter_fraction,
            locator = locator,
            updated_at = updated_at,
        })
    end)
end

--- Asynchronously drain queued progress entries one at a time.
---@param source BookSource
---@param show_msg boolean|nil
---@param cb fun(ok_count: integer)|nil
---@return { cancel: fun() }|nil
function Progress.flushPendingAsync(source, show_msg, cb)
    if not source or not source.id then
        if cb then cb(0) end
        return nil
    end
    local caps = source.capabilities and source:capabilities() or {}
    if not caps.progress_push or not source.putProgressAsync then
        if cb then cb(0) end
        return nil
    end
    local rows = ProgressDB.all(source.id)
    local ok_n = 0
    local i = 1
    local cancelled = false
    local active_job
    local function finish()
        if cancelled then
            return
        end
        if show_msg then
            UIManager:show(InfoMessage:new{
                text = ok_n > 0 and T(_("已同步 %1 条进度"), ok_n) or _("无可同步进度"),
                timeout = 2,
            })
        end
        if cb then cb(ok_n) end
    end
    local function drain()
        if cancelled then
            return
        end
        local row = rows[i]
        i = i + 1
        if not row then
            finish()
            return
        end
        local ref = BookRef.new(row.source_id, row.stable_id)
        local pos = {
            fraction = row.fraction,
            chapter_idx = row.chapter_idx,
            chapter_fraction = row.chapter_fraction,
            locator = row.locator,
        }
        active_job = source:putProgressAsync(ref, pos, function(res, err)
            if cancelled then
                return
            end
            if res then
                local src_id = row.source_id
                local s_id = row.stable_id
                DbQueue.run(function()
                    ProgressDB.delete(src_id, s_id)
                end)
                ok_n = ok_n + 1
            else
                logger.warn("book.progress flush failed", row.stable_id, err)
            end
            UIManager:nextTick(drain)
        end)
    end
    UIManager:nextTick(drain)
    return {
        cancel = function()
            cancelled = true
            if active_job and active_job.cancel then
                active_job:cancel()
            end
        end,
    }
end

--- 上传进度：先入队，上线后推送并删队
--- 上传成功后校验队列中是否仍有相同进度，避免新版本被旧回调误删。
---@param ui table
---@param source BookSource
---@param show_msg boolean|nil
function Progress.push(ui, source, show_msg)
    local id = Progress.identityFor(ui)
    if not id or not id.ref or not source then
        return
    end
    local caps = source.capabilities and source:capabilities() or {}
    if not caps.progress_push then
        return
    end
    local pos = Progress.position(ui)
    if not pos then
        return
    end
    enqueue(id.ref, pos)
    local queued_at = pos.updated_at or os.time()
    local queued_frac = pos.fraction
    NetworkMgr:runWhenOnline(function()
        if not source.putProgressAsync then
            return
        end
        source:putProgressAsync(id.ref, pos, function(res, err)
            if res then
                -- 校验：队列中若仍有相同进度（同一版本），才删除；
                -- 否则说明有新进度已入队，留给下次上传。
                local pending = ProgressDB.all(id.ref.source_id)
                for _, p in ipairs(pending) do
                    if p.stable_id == id.ref.stable_id
                        and math.abs(p.fraction - queued_frac) < 0.0001
                        and math.abs(p.updated_at - queued_at) < 2 then
                        local src_id = id.ref.source_id
                        local s_id = id.ref.stable_id
                        DbQueue.run(function()
                            ProgressDB.delete(src_id, s_id)
                        end)
                        break
                    end
                end
                Progress.flushPendingAsync(source, false, function()
                    if show_msg then
                        UIManager:show(InfoMessage:new{ text = _("进度已上传"), timeout = 2 })
                    end
                end)
            else
                logger.warn("book push progress failed", err)
                if show_msg then
                    UIManager:show(InfoMessage:new{
                        text = err or _("上传失败，已保留待同步"),
                        timeout = 2,
                    })
                end
            end
        end)
    end)
end

--- 从数据源拉取进度并应用到当前文档
---@param ui table
---@param source BookSource
---@param show_msg boolean|nil
function Progress.pull(ui, source, show_msg)
    local id = Progress.identityFor(ui)
    if not id or not id.ref or not source then
        return
    end
    local caps = source.capabilities and source:capabilities() or {}
    if not caps.progress_pull then
        return
    end
    NetworkMgr:runWhenOnline(function()
        local function getRemote()
            if not source.getProgressAsync then
                return
            end
            source:getProgressAsync(id.ref, function(pos, err)
                -- 校验当前文档身份：若用户已切换到其他书，跳过进度应用
                local cur_id = Progress.identityFor(ui)
                if not cur_id or not cur_id.ref
                    or cur_id.ref.source_id ~= id.ref.source_id
                    or cur_id.ref.stable_id ~= id.ref.stable_id then
                    logger.dbg("book.progress pull skip: document changed")
                    return
                end
                if not pos then
                    if show_msg then
                        UIManager:show(InfoMessage:new{ text = err or _("拉取失败") })
                    end
                    return
                else
                    local pct = ProgressPosition.clampFraction(pos.fraction)
                    local local_frac = Progress.fraction(ui)
                    if math.abs(local_frac - pct) < 0.01 then
                        return
                    end

                    local Chapter = require("chapters.init")
                    local chapter_mode = id.chapter_idx and Chapter.isActive()
                    if chapter_mode then
                        local count = Chapter.chapterCount() or 1
                        local target_idx = pos.chapter_idx
                        local within = pos.chapter_fraction or pct
                        if not target_idx then
                            local p = pct * count
                            target_idx = math.max(1, math.min(count, math.floor(p) + 1))
                            within = p - (target_idx - 1)
                        elseif pos.chapter_fraction then
                            within = pos.chapter_fraction
                        else
                            local p = pct * count
                            local expect = math.floor(p) + 1
                            if expect == target_idx then
                                within = p - (target_idx - 1)
                            else
                                within = 0
                            end
                        end
                        if Chapter.isActive() and target_idx ~= id.chapter_idx then
                            Chapter.gotoChapter(target_idx, { within = within })
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
            end)
        end
        Progress.flushPendingAsync(source, false, getRemote)
    end)
end

return Progress
