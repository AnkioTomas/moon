--[[--
整书模式：KOReader 文档内目录（crengine / ReaderToc）。

@module koplugin.book.ui.reader.session.document_toc
--]]

local Event = require("ui/event")

local DocumentToc = {}

---@param ui table|nil
---@return table|nil ReaderToc
local function readerToc(ui)
    return ui and ui.toc
end

---@param ui table|nil
---@return table|nil
local function rawToc(ui)
    local toc_mod = readerToc(ui)
    if not toc_mod or not ui.document then
        return nil
    end
    if type(toc_mod.fillToc) == "function" then
        pcall(toc_mod.fillToc, toc_mod)
    elseif type(ui.document.getToc) == "function" then
        local ok, items = pcall(ui.document.getToc, ui.document)
        if ok and type(items) == "table" then
            toc_mod.toc = items
        end
    end
    local items = toc_mod.toc
    if type(items) ~= "table" or #items == 0 then
        if type(ui.document.getToc) == "function" then
            local ok, fallback = pcall(ui.document.getToc, ui.document)
            items = ok and fallback or nil
        end
    end
    if type(items) ~= "table" or #items == 0 then
        return nil
    end
    return items
end

---@param ui table|nil
---@return BookChapter[]|nil
function DocumentToc.list(ui)
    local items = rawToc(ui)
    if not items then return nil end
    local out = {}
    for i, entry in ipairs(items) do
        if type(entry) == "table" then
            local title = entry.title
            if type(title) ~= "string" or title == "" then
                title = "#" .. i
            end
            out[#out + 1] = {
                idx = i,
                title = title,
                page = entry.page,
                xpointer = entry.xpointer,
            }
        end
    end
    return #out > 0 and out or nil
end

---@param ui table|nil
---@return number|string|nil
local function currentLocator(ui)
    if not ui or not ui.document then return nil end
    if type(ui.document.getXPointer) == "function" then
        local ok, xptr = pcall(ui.document.getXPointer, ui.document)
        if ok and type(xptr) == "string" and xptr ~= "" then
            return xptr
        end
    end
    if type(ui.getCurrentPage) == "function" then
        local ok, page = pcall(ui.getCurrentPage, ui)
        if ok then return page end
    end
    return nil
end

---@param ui table|nil
---@return integer|nil
local function currentIndex(ui)
    local toc_mod = readerToc(ui)
    local locator = currentLocator(ui)
    if not toc_mod or locator == nil then return nil end
    if type(toc_mod.getTocIndexByPage) == "function" then
        local ok, idx = pcall(toc_mod.getTocIndexByPage, toc_mod, locator)
        idx = ok and tonumber(idx) or nil
        if idx and idx > 0 then return idx end
    end
    local page = tonumber(locator)
    local items = rawToc(ui)
    if not page or not items then return nil end
    local prev = 0
    for i, entry in ipairs(items) do
        local entry_page = tonumber(entry.page)
        if entry_page and entry_page <= page then
            prev = i
        elseif entry_page and entry_page > page then
            break
        end
    end
    return prev > 0 and prev or nil
end

---@param ui table|nil
---@return { idx: integer, title: string }|nil
function DocumentToc.current(ui)
    local idx = currentIndex(ui)
    if not idx then return nil end
    local list = DocumentToc.list(ui)
    local entry = list and list[idx]
    if not entry then return nil end
    return { idx = idx, title = entry.title }
end

---@param ui table|nil
---@return number|nil
function DocumentToc.chapterFraction(ui)
    local toc_mod = readerToc(ui)
    local page = tonumber(currentLocator(ui))
    if not toc_mod or not page then return nil end
    if type(toc_mod.getChapterPagesDone) == "function"
        and type(toc_mod.getChapterPagesLeft) == "function" then
        local ok_done, done = pcall(toc_mod.getChapterPagesDone, toc_mod, page)
        local ok_left, left = pcall(toc_mod.getChapterPagesLeft, toc_mod, page)
        done = ok_done and tonumber(done)
        left = ok_left and tonumber(left)
        if done and left and (done + left) > 0 then
            return math.max(0, math.min(1, done / (done + left)))
        end
    end
    return nil
end

---@param ui table|nil
---@param idx integer
---@param opts { within: number|nil }|nil
---@return boolean
function DocumentToc.gotoIndex(ui, idx, opts)
    local list = DocumentToc.list(ui)
    if not list or idx < 1 or idx > #list then return false end
    local entry = list[idx]
    if not entry or not ui or not ui.handleEvent then return false end
    if opts and opts.within ~= nil and entry.page and ui.document then
        local within = require("types.book_progress").clampFraction(opts.within)
        if type(ui.document.getXPointerFromProportion) == "function" then
            local ok, xptr = pcall(function()
                local start = entry.xpointer
                local next_entry = list[idx + 1]
                local end_xptr = next_entry and next_entry.xpointer
                if start and end_xptr and type(ui.document.compareXPointers) == "function" then
                    return start
                end
                local total = ui.document:getPageCount() or 1
                local start_page = entry.page or 1
                local end_page = next_entry and next_entry.page or total
                local page = math.max(start_page, math.min(end_page,
                    math.floor(start_page + (end_page - start_page) * within + 0.5)))
                return ui.document:getPageXPointer(page)
            end)
            if ok and xptr and ui.rolling then
                ui.rolling:onGotoXPointer(xptr)
                return true
            elseif ok and xptr and ui.link then
                ui.link:onGotoXPointer(xptr)
                return true
            end
        end
        local total = ui.document.getPageCount and ui.document:getPageCount() or 1
        local start_page = entry.page or 1
        local next_entry = list[idx + 1]
        local end_page = next_entry and next_entry.page or total
        local page = math.max(start_page, math.min(end_page,
            math.floor(start_page + (end_page - start_page) * within + 0.5)))
        ui:handleEvent(Event:new("GotoPage", page))
        return true
    end
    if type(entry.xpointer) == "string" and entry.xpointer ~= "" then
        ui:handleEvent(Event:new("GotoXPointer", entry.xpointer, entry.xpointer))
        return true
    end
    if entry.page then
        ui:handleEvent(Event:new("GotoPage", entry.page))
        return true
    end
    return false
end

---@param ui table|nil
---@param delta integer
---@return boolean
function DocumentToc.onBoundary(ui, delta)
    local toc_mod = readerToc(ui)
    local page = tonumber(currentLocator(ui))
    if not toc_mod or not page or not ui or not ui.handleEvent then return false end
    local target
    if delta > 0 and type(toc_mod.getNextChapter) == "function" then
        local ok, next_page = pcall(toc_mod.getNextChapter, toc_mod, page)
        target = ok and next_page or nil
    elseif delta < 0 and type(toc_mod.getPreviousChapter) == "function" then
        local ok, prev_page = pcall(toc_mod.getPreviousChapter, toc_mod, page)
        target = ok and prev_page or nil
    end
    if not target then return false end
    ui:handleEvent(Event:new("GotoPage", target))
    return true
end

return DocumentToc
