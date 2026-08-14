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
local Db = require("utils.db")
local SourceError = require("source.error")
local Contract = require("source.contract")
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
    local Chapter = require("book.chapter")
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
    pct = Contract.clampFraction(pct)
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

--- 进度入队待上传。
---@param ref BookRef
---@param pos ProgressPosition
---@return boolean
local function enqueue(ref, pos)
    if not ref or not pos then
        return false
    end
    return Db.upsertPendingProgress(ref.source_id, ref.stable_id, pos)
end

--- 冲刷待上传进度（按 source.id）
---@param source BookSource
---@param show_msg boolean|nil
---@return integer ok_count
function Progress.flushPending(source, show_msg)
    if not source or not source.id then
        return 0
    end
    local caps = source.capabilities and source:capabilities() or {}
    if not caps.progress_push then
        return 0
    end
    local rows = Db.allPendingProgress(source.id)
    local ok_n = 0
    for _, row in ipairs(rows) do
        local ref = Contract.makeRef(row.source_id, row.stable_id)
        local pos = {
            fraction = row.fraction,
            chapter_idx = row.chapter_idx,
            chapter_fraction = row.chapter_fraction,
            locator = row.locator,
        }
        local res, err = source:putProgress(ref, pos)
        if res then
            Db.deletePendingProgress(row.source_id, row.stable_id)
            ok_n = ok_n + 1
        else
            logger.warn("book.progress flush failed", row.stable_id, SourceError.message(err))
        end
    end
    if show_msg then
        UIManager:show(InfoMessage:new{
            text = ok_n > 0 and T(_("已同步 %1 条进度"), ok_n) or _("无可同步进度"),
            timeout = 2,
        })
    end
    return ok_n
end

--- 上传进度：先入队，上线后推送并删队
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
    logger.dbg("book.progress push queued", id.ref.stable_id, pos.fraction, pos.chapter_idx)
    NetworkMgr:runWhenOnline(function()
        local res, err = source:putProgress(id.ref, pos)
        if res then
            Db.deletePendingProgress(id.ref.source_id, id.ref.stable_id)
            Progress.flushPending(source, false)
            if show_msg then
                UIManager:show(InfoMessage:new{ text = _("进度已上传"), timeout = 2 })
            end
        else
            logger.warn("book push progress failed", SourceError.message(err))
            if show_msg then
                UIManager:show(InfoMessage:new{
                    text = SourceError.message(err) or _("上传失败，已保留待同步"),
                    timeout = 2,
                })
            end
        end
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
    logger.dbg("book.progress pull", id.ref.stable_id)
    NetworkMgr:runWhenOnline(function()
        Progress.flushPending(source, false)
        local pos, err = source:getProgress(id.ref)
        if not pos then
            if show_msg then
                UIManager:show(InfoMessage:new{ text = SourceError.message(err) or _("拉取失败") })
            end
            return
        end
        local pct = Contract.clampFraction(pos.fraction)
        local local_frac = Progress.fraction(ui)
        if math.abs(local_frac - pct) < 0.01 then
            return
        end

        local Chapter = require("book.chapter")
        if id.chapter_idx and Chapter.isActive() then
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
            if target_idx ~= id.chapter_idx then
                Chapter.gotoChapter(target_idx, { within = within, plugin = ui })
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
    end)
end

return Progress
