--[[--
阅读统计采集：阅读开始计时、翻页结清、暂停落盘，写入 reading_stats。

只统计有源身份（BookRef）的文档；本地书无源可报，直接跳过。
一页一条：duration 为该页停留秒数，过短（< 1s）丢弃。

接线（main.lua）：reader_ready / resume → start；page/pos update → onPage；
close_document / suspend → stop。

@module koplugin.book.stats.tracker
--]]

local Store = require("book.store")
local StatsDB = require("utils.db.stats")
local DbQueue = require("utils.db.queue")

local Tracker = {
    ---@type { ref: BookRef, page: number, total_pages: number, started_at: number }|nil
    _cur = nil,
}

--- 结清一页并异部落盘。
---@param cur { ref: BookRef, page: number, total_pages: number, started_at: number }
local function settle(cur)
    local duration = os.time() - cur.started_at
    if duration < 1 then
        return
    end
    local row = {
        source_id = cur.ref.source_id,
        stable_id = cur.ref.stable_id,
        page = cur.page,
        start_time = cur.started_at,
        duration = duration,
        total_pages = cur.total_pages,
    }
    DbQueue.run(function()
        StatsDB.add(row)
    end)
end

--- 结清当前页并重置会话。
local function flush()
    local cur = Tracker._cur
    Tracker._cur = nil
    if cur then
        settle(cur)
    end
end

--- 当前页码（取不到按 1）。
---@param ui table|nil
---@return number
local function currentPage(ui)
    if ui and ui.getCurrentPage then
        return tonumber(ui:getCurrentPage()) or 1
    end
    return 1
end

--- 当前文档总页数（取不到按 0）。
---@param ui table|nil
---@return number
local function totalPages(ui)
    local doc = ui and ui.document
    if doc and doc.getPageCount then
        return tonumber(doc:getPageCount()) or 0
    end
    return 0
end

--- 开始/恢复阅读计时（reader_ready / resume）。非源书籍不统计。
---@param ui table
---@return nil
function Tracker.start(ui)
    flush() -- 兜底结清上一段（异常路径）
    if not ui or not ui.document or not ui.document.file then
        return
    end
    local id = Store.identityFor(ui.document.file)
    if not id or not id.ref then
        return
    end
    Tracker._cur = {
        ref = id.ref,
        page = currentPage(ui),
        total_pages = totalPages(ui),
        started_at = os.time(),
    }
end

--- 翻页：结清旧页，开新页（同会话内）。
---@param ui table
---@param page number|nil
---@return nil
function Tracker.onPage(ui, page)
    local cur = Tracker._cur
    page = tonumber(page)
    if not cur or not page or page == cur.page then
        return
    end
    settle(cur)
    cur.page = page
    cur.total_pages = totalPages(ui)
    cur.started_at = os.time()
end

--- 停止计时并结清（close_document / suspend）。
---@return nil
function Tracker.stop()
    flush()
end

return Tracker
