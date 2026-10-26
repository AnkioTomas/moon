--[[--
锁屏背景：单向历。本地自绘的日历页（不取任何外部图片），灰阶细线、大块留白，适合墨水屏。

竖屏自上而下：刊头（月读 / 年月）→ 巨号公历日 → 英文月份与星期 → 农历月日、干支生肖、节气 / 节日
→ 每日一句（全库划线按日期固定挑一句，没有划线用内置句子）→ 页脚（第几天 / 全年天数）。
横屏左栏放日期与农历，右栏放句子。
农历取 online.myrl 的当日缓存（和首页时钟同一份）；锁屏只读缓存并 ensure 入队，不等网络。
缓存不是今天的就不画农历三行。
plan() 只算绘制指令（可单测），绘制复用文字海报的 metrics / paint。

@module koplugin.book.features.lockscreen.danxiangli
--]]

local T = require("features.lockscreen.typo_text")
local Typo = require("features.lockscreen.typo")

local M = {}

local BLACK, INK, GRAY = 0x00, 0x33, 0x77

local MONTHS = { "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER" }
local WEEK_EN = { "SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY" }
local WEEK_ZH = { "星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六" }

local function fmt(n) return math.floor(n + 0.5) end

local function leap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end

--- 农历行：myrl 日报 → { date, ganzhi, term? }；没有农历就是 nil。
---@param daily table|nil online.myrl 的 parse 结果
---@return table|nil
function M.lunarLines(daily)
    if type(daily) ~= "table" or type(daily.lunar) ~= "string" then return nil end
    local date = daily.lunar:gsub("^农历", "")
    if date == "" then return nil end
    local lines = { date = date }
    if type(daily.ganzhi) == "string" then
        -- "丙午年 戊戌月 壬戌日" → "丙午马年 · 戊戌月 · 壬戌日"
        local parts = {}
        for part in daily.ganzhi:gmatch("%S+") do parts[#parts + 1] = part end
        if parts[1] and type(daily.animal) == "string" then
            parts[1] = parts[1]:gsub("年$", daily.animal .. "年")
        end
        lines.ganzhi = #parts > 0 and table.concat(parts, " · ") or nil
    end
    if daily.term then
        lines.term = "今日" .. daily.term
    else
        lines.term = daily.festival or daily.holiday
    end
    return lines
end

--- 今天的 myrl 日报：只读未过期缓存，日期对不上不用；顺手 ensure（过期才入队，不阻塞）。
---@param date table
---@return table|nil
function M.daily(date)
    local Myrl = require("online.myrl")
    require("ui.guard").call("danxiangli myrl ensure", function() Myrl:ensure() end)
    local data = Myrl:current()
    if not data then return nil end
    if data.ymd and data.ymd ~= string.format("%04d-%02d-%02d", date.year, date.month, date.day) then
        return nil
    end
    return data
end

--- 当天的日历字段。date = os.date("*t") 形状；daily 是 myrl 日报（缺省读缓存）。
---@param date table
---@param daily table|nil|false false = 不取农历
---@return table
function M.day(date, daily)
    local y, m, d = date.year, date.month, date.day
    local t = os.time({ year = y, month = m, day = d, hour = 12 })
    local info = os.date("*t", t)
    if daily == nil then daily = M.daily(date) end
    return {
        year = y, month = m, day = d, wday = info.wday, yday = info.yday,
        total = leap(y) and 366 or 365,
        month_en = MONTHS[m], week_en = WEEK_EN[info.wday], week_zh = WEEK_ZH[info.wday],
        lunar = daily and M.lunarLines(daily) or nil,
    }
end

local function textOp(ops, s, x, y, size, gray, bold)
    ops[#ops + 1] = { t = "text", s = s, x = fmt(x), y = fmt(y), size = fmt(size), gray = gray, bold = bold }
end

local function rectOp(ops, x, y, w, h, gray)
    ops[#ops + 1] = { t = "rect", x = fmt(x), y = fmt(y), w = math.max(1, fmt(w)), h = math.max(1, fmt(h)), gray = gray }
end

local function centered(ops, s, cx, y, size, gray, bold, measure)
    textOp(ops, s, cx - measure(s, size, bold) / 2, y, size, gray, bold)
end

--- 字距拉开的英文小字：逐字母排。
local function spaced(s, size, measure)
    local w = 0
    for ch in s:gmatch(".") do w = w + measure(ch, size) + size * 0.35 end
    return w - size * 0.35
end

local function spacedText(ops, s, x, y, size, gray, measure)
    for ch in s:gmatch(".") do
        textOp(ops, ch, x, y, size, gray)
        x = x + measure(ch, size) + size * 0.35
    end
end

--- 句子在 width × max_h 里取最大字号（max→min 每次缩 6%）。
local function fitQuote(text, width, max_size, min_size, max_h, lh, measure)
    local size = max_size
    while true do
        local lines = T.breakLines(text, width, function(u) return measure(u, size) end)
        if #lines * size * lh <= max_h or size <= min_size then
            while #lines * size * lh > max_h and #lines > 1 do lines[#lines] = nil end
            return size, lines
        end
        size = math.max(min_size, size * 0.94)
    end
end

--- 日期块：巨号日 + 英文月星期 + 农历三行，居中于 [x, x+bw]，返回底部 y。
local function dateBlock(ops, c, x, bw, y, big, measure)
    local cx = x + bw / 2
    local en = c.month_en .. "  " .. c.week_en
    local small = math.min(big * 0.11, bw / spaced(en, 1, measure))
    local day = string.format("%d", c.day)
    local ds = math.min(big, bw * 0.92 / math.max(0.01, measure(day, 1, true)))
    centered(ops, day, cx, y, ds, BLACK, true, measure)
    y = y + ds * 1.02
    local ew = spaced(en, small, measure)
    spacedText(ops, en, cx - ew / 2, y, small, INK, measure)
    y = y + small * 2
    centered(ops, c.week_zh, cx, y, small * 1.5, BLACK, true, measure)
    y = y + small * 2.6
    rectOp(ops, cx - bw * 0.18, y, bw * 0.36, 1, GRAY)
    y = y + small * 1.6
    if c.lunar then
        local ls = small * 2.1
        centered(ops, c.lunar.date, cx, y, ls, BLACK, true, measure)
        y = y + ls * 1.45
        if c.lunar.ganzhi then
            centered(ops, c.lunar.ganzhi, cx, y, small * 1.25, INK, false, measure)
            y = y + small * 1.25 * 1.6
        end
        if c.lunar.term then
            centered(ops, c.lunar.term, cx, y, small * 1.25, INK, false, measure)
            y = y + small * 1.25 * 1.4
        end
    end
    return y
end

local function quoteBlock(ops, q, x, width, top, bottom, base, measure)
    local att = Typo.attribution(q)
    local as = base * 0.62
    local avail = bottom - top - (att ~= "" and as * 2.4 or 0)
    local size, lines = fitQuote(T.strip(q.text), width, base, base * 0.6, avail, 1.7, measure)
    local block = #lines * size * 1.7 + (att ~= "" and as * 2.4 or 0)
    local y = top + math.max(0, (bottom - top - block) / 2)
    for _idx, line in ipairs(lines) do
        textOp(ops, line, x, y, size, BLACK)
        y = y + size * 1.7
    end
    if att ~= "" then
        y = y + as * 0.8
        local aw = measure(att, as)
        textOp(ops, att, math.max(x, x + width - aw), y, as, GRAY)
    end
end

local function header(ops, c, m, w, y, small, measure)
    textOp(ops, "月读", m, y, small, BLACK, true)
    local right = string.format("%d.%02d", c.year, c.month)
    textOp(ops, right, w - m - measure(right, small), y, small, INK)
    y = y + small * 1.8
    rectOp(ops, m, y, w - m * 2, math.max(2, small * 0.12), BLACK)
    return y
end

local function footer(ops, c, m, w, h, small, measure)
    local y = h - m - small
    rectOp(ops, m, y - small * 0.9, w - m * 2, 1, GRAY)
    textOp(ops, "MOON · 月读", m, y, small, GRAY)
    local tail = string.format("NO.%03d / %d", c.yday, c.total)
    textOp(ops, tail, w - m - measure(tail, small), y, small, GRAY)
end

--- 算绘制指令。c = M.day(...)，q = {text, title, author}；measure(text, px, bold) 返回像素宽。
---@return table[]
function M.plan(c, q, w, h, measure)
    local ops = {}
    local m = math.min(w, h) * 0.08
    local small = math.min(w, h) * 0.024
    local top = header(ops, c, m, w, m, small, measure)
    footer(ops, c, m, w, h, small, measure)
    local bottom = h - m - small * 2.2
    if w > h then
        local lw = (w - m * 2) * 0.42
        -- 日期块高约 2.45 × big（巨号 1.02 + 小字行 13 × 0.11）
        local big = math.min(lw * 0.8, (bottom - top - small * 2) / 2.5)
        dateBlock(ops, c, m, lw, top + math.max(small, (bottom - top - big * 2.45) / 2), big, measure)
        local rx = m + lw + (w - m * 2) * 0.06
        rectOp(ops, m + lw + (w - m * 2) * 0.03, top + small * 2, 1, bottom - top - small * 4, GRAY)
        quoteBlock(ops, q, rx, w - m - rx, top + small * 2, bottom - small, math.min(w, h) * 0.042, measure)
    else
        local inner = w - m * 2
        local big = math.min(inner * 0.62, (bottom - top) * 0.3)
        local y = dateBlock(ops, c, m, inner, top + small * 1.5, big, measure)
        rectOp(ops, m, y + small * 0.6, inner, 1, BLACK)
        rectOp(ops, m, y + small * 0.6 + 4, inner, 1, BLACK)
        quoteBlock(ops, q, m + inner * 0.04, inner * 0.92, y + small * 2.4, bottom - small, w * 0.044, measure)
    end
    return ops
end

--- 同一天固定同一句：划线（6–80 字）按日序取模，没有就用文字海报的内置句子。
---@param c table
---@param items table[]|nil 默认全库划线
---@return table
function M.pickQuote(c, items)
    local pool = Typo.shortQuotes(80, items)
    if #pool == 0 then pool = Typo.FALLBACK end
    local seed = c.year * 400 + c.yday
    return pool[seed % #pool + 1]
end

--- 全屏背景块。
---@param rect table
---@return table[]
function M.blocks(rect)
    local w = math.max(1, tonumber(rect.w) or 1)
    local h = math.max(1, tonumber(rect.h) or 1)
    local c = M.day(os.date("*t") --[[@as osdate]])
    local face, measure, synthetic = Typo.metrics()
    local ops = M.plan(c, M.pickQuote(c), w, h, measure)
    T.release()
    local widget = {}
    function widget:getSize() return { w = w, h = h } end
    function widget:paintTo(bb, x, y) Typo.paint(bb, ops, x, y, face, synthetic) end
    return {{ kind = "widget", widget = widget, x = 0, y = 0, width = w, height = h }}
end

--- 一天一页；农历到货后键变，组合图重画。
---@return string
function M.cache_key()
    local date = os.date("*t") --[[@as osdate]]
    local lunar = M.lunarLines(M.daily(date))
    return os.date("%Y-%m-%d") .. (lunar and ("|" .. lunar.date) or "")
end

return M
