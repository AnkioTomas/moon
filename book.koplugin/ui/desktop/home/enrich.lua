--[[--
首页书籍行：合并 ProgressDB 章节与进度（显示用，不写库）。

@module koplugin.book.ui.desktop.home.enrich
--]]

local ProgressDB = require("db.progress")

local Enrich = {}

--- 单本书合并 pending_progress。
---@param book table|nil
---@return table|nil
function Enrich.book(book)
    if type(book) ~= "table" then return book end
    local source_id, stable_id = book.source_id, book.stable_id
    if type(source_id) ~= "string" or type(stable_id) ~= "string" or stable_id == "" then
        return book
    end
    local progress = ProgressDB.get(source_id, stable_id) or {}
    if progress.chapter_title then
        book.chapter_title = progress.chapter_title
    end
    if progress.chapter_idx then
        book.chapter_idx = progress.chapter_idx
    end
    if progress.fraction ~= nil then
        book.percent = math.floor(tonumber(progress.fraction) * 100 + 0.5)
    end
    if progress.page then book.page = progress.page end
    if progress.total_pages then book.total_pages = progress.total_pages end
    return book
end

--- 批量 enrich；recent 与 reading 列表共用。
---@param recent table|nil
---@param reading table[]|nil
---@return table|nil, table[]
function Enrich.apply(recent, reading)
    recent = Enrich.book(recent)
    local out = {}
    for i, row in ipairs(reading or {}) do
        out[#out + 1] = Enrich.book(row)
    end
    return recent, out
end

return Enrich
