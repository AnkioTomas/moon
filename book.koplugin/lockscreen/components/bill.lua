--[[--
主体：阅读账单。仅宽屏。

@module koplugin.book.lockscreen.components.bill
--]]

local Context = require("lockscreen.context")
local Chart = require("ui.components.chart")
local Blitbuffer = require("ffi/blitbuffer")
local U = require("lockscreen.components.util")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "bill",
    label = _("阅读账单"),
    supports_narrow = false,
    needs_network = false,
}

---@param period string
---@return string
local function periodLabel(period)
    local labels = {
        today = _("今日"),
        ["7d"] = _("最近 7 天"),
        ["30d"] = _("最近 30 天"),
        month = _("本月"),
    }
    return labels[period] or labels["7d"]
end

---@param seconds number|nil
---@return string
local function duration(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return minutes >= 60 and T(_("%1小时%2分"), math.floor(minutes / 60), minutes % 60)
        or T(_("%1分钟"), minutes)
end

---@param rect table
---@return table[]
function M.blocks(rect)
    local bill = Context.bill()
    local summary = bill.summary or {}
    local grain = bill.grain or "day"
    local buckets = bill.buckets or bill.days or {}
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
            text = periodLabel(bill.period) .. "  "
                .. os.date("%Y.%m.%d", bill.start_ts or os.time()) .. " - "
                .. os.date("%Y.%m.%d", (bill.end_ts or os.time()) - 1),
            x = inner_x, y = y0 + math.floor(h * 0.10), width = inner_w, size = 15, box = false, color = U.MUTED,
        },
        { kind = "rule", x = inner_x, y = y0 + math.floor(h * 0.15), width = inner_w, height = 1 },
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
        { kind = "rule", x = inner_x, y = y0 + math.floor(h * 0.32), width = inner_w, height = 1 },
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
    blocks[#blocks + 1] = { kind = "rule", x = inner_x, y = chart_y - 16, width = inner_w, height = 1 }
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
