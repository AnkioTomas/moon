--[[--
阅读快照工具：页码、比例、剩余时间估算。

@module koplugin.book.ui.reader.session.snapshot
--]]

---@class ReaderSessionSnapshot
---@field ui table 当前 ReaderUI
---@field identity BookIdentity 当前物理文档身份
---@field page integer 当前文档页码
---@field total_pages integer 当前文档页数
---@field doc_fraction number 当前文档阅读比例（0..1）
---@field fraction number 全书阅读比例（0..1）
---@field chapter_fraction number|nil 当前章节阅读比例（0..1）
---@field percent number 全书阅读百分比（0..100）
---@field reading_chapter_idx integer|nil 当前目录章序号（两种模式 toc 可用时）
---@field chapter ReaderChapterSession|nil 当前文档的章节上下文

local Snapshot = {}

---@type string|nil
local speed_key
---@type { total_seconds: number, pages: number }|nil
local speed_summary

--- 转成有限数字，NaN / ±inf / 低于下限一律判为无效。
--- 页数与速度都参与除法，脏值必须在入口挡掉而不是让 NaN 扩散到进度里。
---@param value any 待校验值
---@param minimum number|nil 允许的最小值
---@return number|nil
local function validNumber(value, minimum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    if minimum and value < minimum then return nil end
    return value
end

---@param ui table
---@param identity BookIdentity
---@return ReaderSessionSnapshot
function Snapshot.new(ui, identity)
    return {
        ui = ui,
        identity = identity,
        page = 0,
        total_pages = 0,
        doc_fraction = 0,
        fraction = 0,
        chapter_fraction = nil,
        percent = 0,
        reading_chapter_idx = nil,
    }
end

---@param ui table|nil
---@param hint number|string|nil
---@param previous number|nil
---@return number
local function readPage(ui, hint, previous)
    local page = validNumber(hint, 1)
    if not page and ui and type(ui.getCurrentPage) == "function" then
        local ok, value = pcall(ui.getCurrentPage, ui)
        if ok then page = validNumber(value, 1) end
    end
    return page and math.floor(page) or previous or 0
end

---@param ui table|nil
---@param previous number|nil
---@return number
local function readTotalPages(ui, previous)
    local document = ui and ui.document
    if document and type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        value = ok and validNumber(value, 0) or nil
        if value then return math.floor(value) end
    end
    return previous or 0
end

---@param ui table|nil
---@param page number
---@param total number
---@return number
local function readDocumentFraction(ui, page, total)
    local document = ui and ui.document
    if document and type(document.getXPointer) == "function"
        and type(document.getProportionFromXPointer) == "function" then
        local ok, value = pcall(function()
            return document:getProportionFromXPointer(document:getXPointer())
        end)
        value = ok and validNumber(value, 0) or nil
        if value then return math.min(1, value) end
    end
    if total > 0 and page > 0 then
        return math.max(0, math.min(1, page / total))
    end
    return 0
end

---@param session ReaderSessionSnapshot
---@param page number|nil
function Snapshot.refresh(session, page)
    local ui = session.ui
    session.page = readPage(ui, page, session.page)
    session.total_pages = readTotalPages(ui, session.total_pages)
    session.doc_fraction = readDocumentFraction(ui, session.page, session.total_pages)
    local Toc = require("ui.reader.session.toc")
    local current = Toc.current(session)
    session.reading_chapter_idx = current and current.idx or nil
    local position = require("book.progress").position(session)
    session.fraction = position.fraction
    session.chapter_fraction = position.chapter_fraction
    session.percent = position.fraction * 100
end

---@param identity BookIdentity|nil
---@return { total_seconds: number, pages: number }|nil
local function readingSummary(identity)
    if type(identity) ~= "table" or not identity.source_id or not identity.stable_id then
        return nil
    end
    local key = identity.source_id .. "/" .. identity.stable_id
    if speed_key == key then
        return speed_summary
    end
    speed_key = key
    speed_summary = require("db.stats").summaryByBook(identity.source_id, identity.stable_id)
    return speed_summary
end

---@param session ReaderSessionSnapshot|nil
---@return number|nil
function Snapshot.remainingSeconds(session)
    if not session or type(session.identity) ~= "table" then
        return nil
    end
    local fraction = tonumber(session.fraction)
    if not fraction or fraction <= 0 or fraction >= 1 then
        return nil
    end
    local summary = readingSummary(session.identity)
    if type(summary) ~= "table" then
        return nil
    end
    local total_seconds = tonumber(summary.total_seconds)
    local pages = tonumber(summary.pages)
    if not total_seconds or total_seconds <= 0 or not pages or pages <= 0 then
        return nil
    end
    return math.floor(total_seconds * (1 - fraction) / fraction)
end

return Snapshot
