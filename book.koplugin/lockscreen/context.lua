--[[--
锁屏数据上下文：当前书、账单与高亮。

@module koplugin.book.lockscreen.context
--]]

local BookDB = require("utils.db.book")
local StatsDB = require("utils.db.stats")
local MoonSettings = require("utils.settings")

local M = {}

---@return table|nil 当前阅读会话
local function currentSession()
    return require("ui.reader.session").current()
end

---@return table|nil 当前书籍及阅读统计；无阅读会话时返回 nil
function M.currentBook()
    local cur = currentSession()
    if not cur or not cur.ref then
        return nil
    end
    local book = cur.book or BookDB.get(cur.ref.source_id, cur.ref.stable_id) or {}
    local stats = StatsDB.summaryByBook(cur.ref.source_id, cur.ref.stable_id)
    return {
        title = book.title or cur.ref.stable_id,
        authors = book.authors or "",
        percent = tonumber(cur.percent) or tonumber(book.percent) or 0,
        page = tonumber(cur.page) or 0,
        total_pages = tonumber(cur.total_pages) or 0,
        chapter_idx = tonumber(cur.chapter_idx),
        chapter_count = tonumber(cur.chapter_count),
        total_seconds = stats.total_seconds,
    }
end

---@param ts number|nil Unix 时间戳；省略时使用当前时间
---@return number 当地时区当天零点时间戳
local function dayStart(ts)
    local t = os.date("*t", ts or os.time())
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

---@param period string|nil today/7d/30d/month；未知值按 7d 处理
---@return number start_ts, number end_ts 账单查询时间范围
function M.billRange(period)
    local now = os.time()
    local finish = now + 1
    if period == "today" then
        return dayStart(now), finish
    elseif period == "30d" then
        return dayStart(now) - 29 * 86400, finish
    elseif period == "month" then
        local t = os.date("*t", now)
        t.day, t.hour, t.min, t.sec = 1, 0, 0, 0
        return os.time(t), finish
    end
    return dayStart(now) - 6 * 86400, finish
end

---@return table {period, start_ts, end_ts, summary, books, days}
function M.bill()
    local c = MoonSettings.get()
    local period = c.lock_screen_bill_period or "7d"
    local start_ts, end_ts = M.billRange(period)
    local source_id = c.active_source or "local"
    return {
        period = period,
        start_ts = start_ts,
        end_ts = end_ts,
        summary = StatsDB.periodSummary(source_id, start_ts, end_ts),
        books = StatsDB.periodBooks(source_id, start_ts, end_ts, 5),
        days = StatsDB.periodDays(source_id, start_ts, end_ts),
    }
end

---@return string|nil 下一条高亮文本；没有可用高亮时返回 nil
function M.highlight()
    local cur = currentSession()
    local annotations = cur and cur.plugin and cur.plugin.ui and cur.plugin.ui.annotation
        and cur.plugin.ui.annotation.annotations
    if type(annotations) ~= "table" then
        return nil
    end
    local texts = {}
    for _, item in ipairs(annotations) do
        -- KOReader annotations do not carry a type field: drawer marks highlights/notes.
        if item.drawer and type(item.text) == "string" and item.text ~= "" then
            texts[#texts + 1] = item.text
        end
    end
    if #texts == 0 then
        return nil
    end
    local c = MoonSettings.get()
    local idx = (tonumber(c.lock_screen_quote_index) or 0) % #texts + 1
    c.lock_screen_quote_index = idx
    MoonSettings.save()
    return texts[idx]
end

return M
