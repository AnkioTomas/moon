--[[--
主体：阅读账单。仅宽屏。

@module koplugin.book.lockscreen.components.bill
--]]

local StatsDB = require("db.stats")
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

local function logoPath()
    local info = debug.getinfo(logoPath, "S")
    local source = info and info.source
    local root = source and source:sub(1, 1) == "@"
        and source:sub(2):match("(.*/)lockscreen/components/[^/]+$")
    return (root or "") .. "logo.png"
end

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
    return {
        period = period,
        start_ts = start_ts,
        end_ts = end_ts,
        summary = StatsDB.periodSummary(source_id, start_ts, end_ts),
        books = StatsDB.periodBooks(source_id, start_ts, end_ts, 5),
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

--- 追加热敏小票常见的虚线分隔。
---@param blocks table[]
---@param x number
---@param y number
---@param width number
local function appendDashes(blocks, x, y, width)
    local right = x + width
    while x < right do
        blocks[#blocks + 1] = {
            kind = "rule", x = x, y = y, width = math.min(6, right - x),
            height = 1, color = U.DIM,
        }
        x = x + 10
    end
end

--- 生成装饰条码；账单号仍以文字显示，不把装饰冒充可扫码编码。
---@param blocks table[]
---@param x number
---@param y number
---@param width number
---@param height number
---@param seed string
local function appendBarcode(blocks, x, y, width, height, seed)
    local right, i = x + width, 1
    while x < right do
        local byte = seed:byte((i - 1) % #seed + 1)
        local bar = 1 + byte % 3
        if i % 4 ~= 0 then
            blocks[#blocks + 1] = {
                kind = "vbar", x = x, y = y, width = math.min(bar, right - x),
                height = height, value = 1, color = Blitbuffer.COLOR_BLACK,
            }
        end
        x = x + bar + 1 + byte % 2
        i = i + 1
    end
end

--- 在热敏纸上下边缘切出连续齿口。
---@param blocks table[]
---@param x number
---@param y number
---@param width number
---@param height number
---@param radius number
local function appendCutouts(blocks, x, y, width, height, radius)
    local step = radius * 3
    local center = x + step
    while center <= x + width - step do
        blocks[#blocks + 1] = {
            kind = "cutout_circle", x = center, y = y, radius = radius,
        }
        blocks[#blocks + 1] = {
            kind = "cutout_circle", x = center, y = y + height, radius = radius,
        }
        center = center + step
    end
end

--- 账单主体：窄长热敏纸、消费明细、合计与条码。
---@param rect table
---@return table[]
function M.blocks(rect)
    local bill = M.data()
    local summary = bill.summary or {}
    local inset = math.floor(rect.w * 0.08)
    local paper_x = rect.x + inset
    local paper_w = rect.w - inset * 2
    local paper_y, paper_h = rect.y, rect.h
    local pad = math.max(18, rect.pad)
    local inner_x, inner_w = paper_x + pad, paper_w - pad * 2
    local number = os.date("%Y%m%d", (bill.end_ts or os.time()) - 1)
    local logo_size = math.max(38, math.floor(paper_h * 0.06))
    local brand_x = inner_x + logo_size + math.floor(pad * 0.6)

    local blocks = {
        {
            kind = "panel", x = paper_x, y = paper_y, width = paper_w, height = paper_h,
            radius = 1, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            kind = "image", file = logoPath(),
            x = inner_x, y = paper_y + math.floor(paper_h * 0.035),
            width = logo_size, height = logo_size, scale_factor = 0, alpha = false,
        },
        {
            text = "MOON READING", x = brand_x, y = paper_y + math.floor(paper_h * 0.045),
            width = inner_w - (brand_x - inner_x), size = 24, bold = true, box = false,
        },
        {
            text = _("阅读账单"), x = brand_x, y = paper_y + math.floor(paper_h * 0.09),
            width = inner_w - (brand_x - inner_x), size = 15, box = false, color = U.MUTED,
        },
        {
            text = "NO." .. number, x = inner_x, y = paper_y + math.floor(paper_h * 0.135),
            width = math.floor(inner_w * 0.5), size = 12, box = false,
        },
        {
            text = os.date("%Y-%m-%d %H:%M"), x = inner_x + math.floor(inner_w * 0.5),
            y = paper_y + math.floor(paper_h * 0.135), width = math.floor(inner_w * 0.5),
            size = 12, align = "right", box = false,
        },
        {
            text = M.periodLabel(bill.period) .. "  "
                .. os.date("%Y.%m.%d", bill.start_ts or os.time()) .. " - "
                .. os.date("%Y.%m.%d", (bill.end_ts or os.time()) - 1),
            x = inner_x, y = paper_y + math.floor(paper_h * 0.175),
            width = inner_w, size = 12, align = "center", box = false, color = U.MUTED,
        },
        {
            text = "ITEM", x = inner_x, y = paper_y + math.floor(paper_h * 0.235),
            width = math.floor(inner_w * 0.58), size = 13, bold = true, box = false,
        },
        {
            text = "PAGES", x = inner_x + math.floor(inner_w * 0.58),
            y = paper_y + math.floor(paper_h * 0.235),
            width = math.floor(inner_w * 0.17), size = 12, align = "right", bold = true, box = false,
        },
        {
            text = "TIME", x = inner_x + math.floor(inner_w * 0.77),
            y = paper_y + math.floor(paper_h * 0.235),
            width = math.floor(inner_w * 0.23), size = 12, align = "right", bold = true, box = false,
        },
    }

    appendDashes(blocks, inner_x, paper_y + math.floor(paper_h * 0.215), inner_w)
    appendDashes(blocks, inner_x, paper_y + math.floor(paper_h * 0.27), inner_w)

    local row_y = paper_y + math.floor(paper_h * 0.29)
    local row_h = math.floor(paper_h * 0.073)
    local books = bill.books or {}
    if #books == 0 then
        blocks[#blocks + 1] = {
            text = _("本周期暂无阅读记录"),
            x = inner_x, y = row_y, width = inner_w, size = 16,
            align = "center", box = false, color = U.MUTED,
        }
    else
        for i, book in ipairs(books) do
            if i > 5 then break end
            blocks[#blocks + 1] = {
                text = string.format("%02d  %s", i, book.title or book.stable_id or ""),
                x = inner_x, y = row_y, width = math.floor(inner_w * 0.58),
                size = 14, bold = true, box = false,
            }
            blocks[#blocks + 1] = {
                text = book.authors or "", x = inner_x, y = row_y + math.floor(row_h * 0.42),
                width = math.floor(inner_w * 0.58), size = 11, box = false, color = U.DIM,
            }
            blocks[#blocks + 1] = {
                text = tostring(tonumber(book.pages) or 0),
                x = inner_x + math.floor(inner_w * 0.58), y = row_y,
                width = math.floor(inner_w * 0.17), size = 13, align = "right", box = false,
            }
            blocks[#blocks + 1] = {
                text = duration(book.seconds),
                x = inner_x + math.floor(inner_w * 0.77), y = row_y,
                width = math.floor(inner_w * 0.23), size = 13, align = "right", box = false,
            }
            row_y = row_y + row_h
        end
    end

    appendDashes(blocks, inner_x, paper_y + math.floor(paper_h * 0.675), inner_w)
    blocks[#blocks + 1] = {
        text = _("书籍"), x = inner_x, y = paper_y + math.floor(paper_h * 0.70),
        width = math.floor(inner_w * 0.5), size = 13, box = false,
    }
    blocks[#blocks + 1] = {
        text = tostring(summary.book_count or 0),
        x = inner_x + math.floor(inner_w * 0.5), y = paper_y + math.floor(paper_h * 0.70),
        width = math.floor(inner_w * 0.5), size = 13, align = "right", box = false,
    }
    blocks[#blocks + 1] = {
        text = _("页数"), x = inner_x, y = paper_y + math.floor(paper_h * 0.735),
        width = math.floor(inner_w * 0.5), size = 13, box = false,
    }
    blocks[#blocks + 1] = {
        text = tostring(summary.pages or 0),
        x = inner_x + math.floor(inner_w * 0.5), y = paper_y + math.floor(paper_h * 0.735),
        width = math.floor(inner_w * 0.5), size = 13, align = "right", box = false,
    }
    appendDashes(blocks, inner_x, paper_y + math.floor(paper_h * 0.775), inner_w)
    blocks[#blocks + 1] = {
        text = "TOTAL", x = inner_x, y = paper_y + math.floor(paper_h * 0.795),
        width = math.floor(inner_w * 0.35), size = 18, bold = true, box = false,
    }
    blocks[#blocks + 1] = {
        text = duration(summary.total_seconds),
        x = inner_x + math.floor(inner_w * 0.35), y = paper_y + math.floor(paper_h * 0.785),
        width = math.floor(inner_w * 0.65), size = 28, bold = true, align = "right", box = false,
    }
    blocks[#blocks + 1] = {
        text = _("谢谢阅读"), x = inner_x, y = paper_y + math.floor(paper_h * 0.845),
        width = inner_w, size = 13, align = "center", box = false, color = U.MUTED,
    }
    appendBarcode(blocks, inner_x, paper_y + math.floor(paper_h * 0.88),
        inner_w, math.max(24, math.floor(paper_h * 0.04)), number)
    blocks[#blocks + 1] = {
        text = "NO." .. number, x = inner_x, y = paper_y + math.floor(paper_h * 0.935),
        width = inner_w, size = 10, align = "center", box = false, color = U.MUTED,
    }
    appendCutouts(blocks, paper_x, paper_y, paper_w, paper_h,
        math.max(7, math.floor(pad * 0.4)))
    return blocks
end

return M
