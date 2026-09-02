--[[--
主体：阅读账单。仅宽屏。

@module koplugin.book.lockscreen.components.bill
--]]

local StatsDB = require("db.stats")
local Chart = require("ui.components.chart")
local Blitbuffer = require("ffi/blitbuffer")
local Library = require("lockscreen.components.library")
local U = require("lockscreen.components.util")
local MoonSettings = require("utils.settings")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "bill",
    label = _("阅读账单"),
    supports_narrow = false,
    supports_position = false,
    preferred_height = 0.90,
    cache_key = function()
        return MoonSettings.get().lock_screen_bill_period or "7d"
    end,
}

local PERIODS = {
    { id = "today", label = _("今日") },
    { id = "7d", label = _("最近 7 天") },
    { id = "30d", label = _("最近 30 天") },
    { id = "month", label = _("本月") },
}

local PERIOD_BY_ID = {}
for _, period in ipairs(PERIODS) do PERIOD_BY_ID[period.id] = period end

--- 账单周期是否是四个合法值之一。
---@param period string|nil
---@return boolean
function M.validPeriod(period)
    return PERIOD_BY_ID[period] ~= nil
end

--- 账单周期的设置页选项。
---@return {text: string, value: string}[]
function M.periodOptions()
    local options = {}
    for _, period in ipairs(PERIODS) do
        options[#options + 1] = { text = period.label, value = period.id }
    end
    return options
end

--- 周期显示名；非法值按最近 7 天显示。
---@param period string|nil
---@return string
function M.periodLabel(period)
    return (PERIOD_BY_ID[period] or PERIOD_BY_ID["7d"]).label
end

--- 组一个图表桶；row 缺失时秒数与页数归零。
---@param key string
---@param label string
---@param row table|nil 统计行（seconds / pages）
---@return table
local function bucket(key, label, row)
    return {
        key = key, label = label,
        seconds = row and (tonumber(row.seconds) or 0) or 0,
        pages = row and (tonumber(row.pages) or 0) or 0,
    }
end

--- 把按小时统计行铺成 0~23 点的 24 个桶，缺失小时补零。
---@param rows table[]|nil 每行含 hour / seconds / pages
---@return table[]
local function hourBuckets(rows)
    local by_hour = {}
    for _, row in ipairs(rows or {}) do
        local hour = tonumber(row.hour)
        if hour then by_hour[hour] = row end
    end
    local buckets = {}
    for hour = 0, 23 do
        local key = string.format("%02d", hour)
        buckets[#buckets + 1] = bucket(key, key, by_hour[hour])
    end
    return buckets
end

--- 账单周期换算成半开区间 [start, end)，end 一律取明日零点（含今天）。
---@param period string today / 7d / 30d / month，其余按 7d 处理
---@return number start_ts, number end_ts
local function billRange(period)
    local now = os.time()
    local finish = U.dayStart(now) + 86400
    if period == "today" then
        return U.dayStart(now), finish
    elseif period == "30d" then
        return U.dayStart(now) - 29 * 86400, finish
    elseif period == "month" then
        local t = os.date("*t", now)
        t.day, t.hour, t.min, t.sec = 1, 0, 0, 0
        return os.time(t), finish
    end
    return U.dayStart(now) - 6 * 86400, finish
end

--- 读取账单周期、统计源和图表桶；账单数据只在账单主体内组装。
---@return table
function M.data()
    local settings = MoonSettings.get()
    local period = settings.lock_screen_bill_period or "7d"
    local start_ts, end_ts = billRange(period)
    local source_id = Library.activeSourceId()
    local grain = period == "today" and "hour" or "day"
    local buckets = grain == "hour"
        and hourBuckets(StatsDB.periodHours(source_id, start_ts, end_ts))
        or U.dayBuckets(StatsDB.periodDays(source_id, start_ts, end_ts), start_ts, end_ts)
    return {
        period = period,
        start_ts = start_ts,
        end_ts = end_ts,
        summary = StatsDB.periodSummary(source_id, start_ts, end_ts),
        books = StatsDB.periodBooks(source_id, start_ts, end_ts, 5),
        grain = grain,
        buckets = buckets,
    }
end

--- 将秒数转成账单卡片使用的短时长文案。
---@param seconds number|nil
---@return string
local function duration(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return minutes >= 60 and T(_("%1小时%2分"), math.floor(minutes / 60), minutes % 60)
        or T(_("%1分钟"), minutes)
end

--- 账单主体固定使用宽屏高卡片，并在底部复用公共柱图组件。
---@param rect table
---@return table[]
function M.blocks(rect)
    local bill = M.data()
    local summary = bill.summary or {}
    local grain = bill.grain or "day"
    local buckets = bill.buckets or {}
    local avg_div
    if grain == "hour" then
        avg_div = math.max(1, (tonumber(os.date("%H")) or 0) + 1)
    else
        avg_div = math.max(1, #buckets)
    end

    local inner_x, inner_w = rect.text_x, rect.text_w
    local pad = rect.pad
    local h = rect.h
    local y0 = rect.y

    local blocks = {
        {
            kind = "panel", x = rect.x, y = y0, width = rect.w, height = h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = _("阅读账单"), x = inner_x, y = y0 + pad,
            width = inner_w, size = 22, bold = true, box = false, align = "right",
        },
        {
            text = os.date("NO.%Y%m%d", (bill.end_ts or os.time()) - 1),
            x = inner_x, y = y0 + pad + 4, width = inner_w / 2, size = 14, box = false, color = U.MUTED,
        },
        {
            text = M.periodLabel(bill.period) .. "  "
                .. os.date("%Y.%m.%d", bill.start_ts or os.time()) .. " - "
                .. os.date("%Y.%m.%d", (bill.end_ts or os.time()) - 1),
            x = inner_x, y = y0 + math.floor(h * 0.10), width = inner_w, size = 15, box = false, color = U.MUTED,
        },
        { kind = "rule", x = inner_x, y = y0 + math.floor(h * 0.15), width = inner_w, height = 1, color = U.RULE },
        {
            text = duration(summary.total_seconds),
            x = inner_x, y = y0 + math.floor(h * 0.18), width = inner_w * 0.58, size = 36, bold = true, box = false,
        },
        {
            text = T(_("阅读 %1 本 · %2 页"), summary.book_count or 0, summary.pages or 0),
            x = math.floor(inner_x + inner_w * 0.55), y = y0 + math.floor(h * 0.20),
            width = math.floor(inner_w * 0.45), size = 15, align = "right", box = false, color = U.MUTED,
        },
        {
            text = _("书单") .. " TOP 5",
            x = inner_x, y = y0 + math.floor(h * 0.28), width = inner_w, size = 16, bold = true, box = false,
        },
        { kind = "rule", x = inner_x, y = y0 + math.floor(h * 0.32), width = inner_w, height = 1, color = U.RULE },
    }

    local y = y0 + math.floor(h * 0.34)
    local row_h = math.floor(h * 0.07)
    local books = bill.books or {}
    if #books == 0 then
        blocks[#blocks + 1] = {
            text = _("本周期暂无阅读记录"),
            x = inner_x, y = y, width = inner_w, size = 18, box = false, color = U.MUTED,
        }
    else
        for i, book in ipairs(books) do
            if i > 5 then break end
            blocks[#blocks + 1] = {
                text = string.format("NO.%02d  %s", i, book.title or book.stable_id or ""),
                x = inner_x, y = y, width = inner_w, size = 16, bold = true, box = false,
            }
            blocks[#blocks + 1] = {
                text = string.format("%s · %.0f%% · %s",
                    book.authors or "", book.percent or 0, duration(book.seconds)),
                x = inner_x, y = y + math.floor(row_h * 0.42),
                width = inner_w, size = 13, box = false, color = U.DIM,
            }
            y = y + row_h
        end
    end

    local chart_y = y0 + math.floor(h * 0.72)
    local avg_label = grain == "hour" and _("时均") or _("日均")
    blocks[#blocks + 1] = { kind = "rule", x = inner_x, y = chart_y - 16, width = inner_w, height = 1, color = U.RULE }
    blocks[#blocks + 1] = {
        text = avg_label .. " " .. duration((summary.total_seconds or 0) / avg_div),
        x = inner_x, y = chart_y, width = inner_w, size = 15, bold = true, box = false,
    }
    Chart.appendBars(blocks, {
        points = buckets,
        value_key = "seconds",
        x = inner_x,
        y = y0 + math.floor(h * 0.78),
        width = inner_w,
        height = math.floor(h * 0.14),
        label_color = U.DIM,
        label_mode = "auto",
    })
    return blocks
end

return M
