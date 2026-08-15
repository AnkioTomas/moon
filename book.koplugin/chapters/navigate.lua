--[[--
按章导航：goto / next / prev / 换文档 / 章末章首 / 页位。

@module koplugin.book.chapters.navigate
--]]

local Store = require("book.store")
local Html = require("chapters.html")
local Session = require("chapters.session")
local Materialize = require("chapters.materialize")
local _ = require("gettext")

local Navigate = {
    _toc_dialog = nil,
    _turning = false,
}

--- 打开/切换到章节文件。
---@param path string
---@param opts { seamless: boolean|nil }|nil
local function showReader(path, opts)
    opts = opts or {}
    local UIManager = require("ui/uimanager")
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    if ui and ui.switchDocument then
        ui:switchDocument(path, opts.seamless ~= false)
        return
    end
    UIManager:nextTick(function()
        ReaderUI:showReader(path, nil, true)
    end)
end

--- ReaderReady：按方向落点，并应用 pending_within。
---@param ui table|nil
function Navigate.onReaderReady(ui)
    local s = Session.get()
    if not s then
        return
    end
    Navigate._turning = false
    Session.clearPendingSwitch()
    local direction = s.open_direction
    s.open_direction = nil
    local within = s.pending_within
    s.pending_within = nil

    if not ui or not ui.document then
        return
    end

    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")

    local function gotoPage(page)
        if not page then
            return
        end
        UIManager:nextTick(function()
            if ui.link then
                ui.link:addCurrentLocationToStack()
            end
            ui:handleEvent(Event:new("GotoPage", page))
        end)
    end

    if type(within) == "number" and within > 0 and within < 1 then
        local ProgressPosition = require("types.book_progress")
        within = ProgressPosition.clampFraction(within)
        UIManager:nextTick(function()
            if ui.document and ui.document.getXPointerFromProportion then
                local xptr = ui.document:getXPointerFromProportion(within)
                if xptr and ui.rolling then
                    ui.rolling:onGotoXPointer(xptr)
                elseif xptr and ui.link then
                    ui.link:onGotoXPointer(xptr)
                end
            elseif ui.document and ui.document.getPageCount then
                local total = ui.document:getPageCount() or 1
                local page = math.max(1, math.min(total, math.floor(within * total + 0.5)))
                gotoPage(page)
            end
        end)
        return
    end

    if direction == "prev" then
        local page_count = ui.document.getPageCount and ui.document:getPageCount() or nil
        if type(page_count) == "number" and page_count > 1 then
            gotoPage(page_count)
        end
    elseif direction == "next" then
        gotoPage(1)
    end
end

--- 跳转到指定章节。
---@param idx number|string
---@param opts { within: number|nil, direction: string|nil }|nil
---@return boolean, string|nil
function Navigate.gotoChapter(idx, opts)
    opts = opts or {}
    local s = Session.get()
    if not s or not s.ref then
        return false, _("无章节会话")
    end
    idx = tonumber(idx) or 1
    local count = Session.chapterCount() or 0
    if idx < 1 or (count > 0 and idx > count) then
        return false, _("章节越界")
    end
    local source = s.source
    local ref = s.ref
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")

    ---@param path string
    ---@return boolean
    local function openPath(path)
        Navigate._turning = false
        local prev_idx = s.idx
        s.idx = idx
        if opts.within ~= nil then
            s.pending_within = opts.within
            s.open_direction = nil
        elseif opts.direction then
            s.open_direction = opts.direction
        elseif prev_idx and idx < prev_idx then
            s.open_direction = "prev"
        elseif prev_idx and idx > prev_idx then
            s.open_direction = "next"
        end
        Store.touchAsync(path, ref, { chapter_idx = idx })
        Session.beginSwitch(path)
        showReader(path, { seamless = true })
        Materialize.prefetchAround(idx)
        if s.plugin then
            s.plugin:emitToSource("chapter_changed", {
                ref = ref,
                chapter_idx = idx,
                book = s.book,
            })
        end
        return true
    end

    local path = Store.chapterPath(ref.stable_id, idx, ref.source_id)
    if Html.isValid(path) then
        return openPath(path)
    end

    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{ text = _("正在加载章节…"), timeout = 1 })
        local gen = s.generation or 0
        Materialize.ensureAsync(source, ref, idx, s.toc, function(ok, p, err)
            local cur = Session.get()
            if not cur or (cur.generation or 0) ~= gen then
                return
            end
            if not ok or not p then
                UIManager:show(InfoMessage:new{ text = err or _("章节下载失败") })
                return
            end
            openPath(p)
        end)
    end)
    return true
end

---@return boolean, string|nil
function Navigate.next()
    local idx = Session.currentIdx()
    if not idx then
        return false
    end
    local count = Session.chapterCount() or 0
    if count > 0 and idx >= count then
        return false, _("已是最后一章")
    end
    return Navigate.gotoChapter(idx + 1, { direction = "next" })
end

---@return boolean, string|nil
function Navigate.prev()
    local idx = Session.currentIdx()
    if not idx then
        return false
    end
    if idx <= 1 then
        return false, _("已是第一章")
    end
    return Navigate.gotoChapter(idx - 1, { direction = "prev" })
end

--- 章末：自动下一章；吞掉默认读完弹窗。
---@return boolean handled
function Navigate.onEndOfBook()
    if not Session.isActive() then
        return false
    end
    if Navigate._turning then
        return true
    end
    local idx = Session.currentIdx()
    local count = Session.chapterCount() or 0
    if not idx or (count > 0 and idx >= count) then
        return false
    end
    Navigate._turning = true
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        Navigate.next()
    end)
    return true
end

--- 章首：自动上一章。
---@return boolean handled
function Navigate.onStartOfBook()
    if not Session.isActive() then
        return false
    end
    if Navigate._turning then
        return true
    end
    local idx = Session.currentIdx()
    if not idx or idx <= 1 then
        return false
    end
    Navigate._turning = true
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        Navigate.prev()
    end)
    return true
end

--- 弹出目录菜单。
---@return boolean
function Navigate.showTocMenu()
    local s = Session.get()
    if not s or type(s.toc) ~= "table" then
        return false
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local buttons = {}
    local cur = s.idx or 1
    for _, ch in ipairs(s.toc) do
        local i = tonumber(ch.idx) or 0
        local title = (ch.title or ("#" .. i))
        if i == cur then
            title = "• " .. title
        end
        buttons[#buttons + 1] = {
            {
                text = title,
                callback = function()
                    if Navigate._toc_dialog then
                        UIManager:close(Navigate._toc_dialog)
                        Navigate._toc_dialog = nil
                    end
                    Navigate.gotoChapter(i)
                end,
            },
        }
    end
    Navigate._toc_dialog = ButtonDialog:new{
        title = _("目录"),
        buttons = buttons,
    }
    UIManager:show(Navigate._toc_dialog)
    return true
end

--- 首次打开起始章（open.lua 用）：不经 switch pending。
---@param path string
function Navigate.showInitial(path)
    showReader(path, { seamless = false })
end

return Navigate
