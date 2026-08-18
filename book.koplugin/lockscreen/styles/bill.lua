--[[--
阅读账单锁屏。

@module koplugin.book.lockscreen.styles.bill
--]]

local Background = require("lockscreen.background")
local Context = require("lockscreen.context")
local Paths = require("utils.paths")
local _ = require("gettext")
local T = require("ffi/util").template

local M = { id = "bill", label = _("阅读账单"), local_render = true }

---@return string 阅读账单图片缓存路径
function M.path()
    return Paths.screensaverDir() .. "/bill.png"
end

---@return string 当前日期 YYYY-MM-DD
function M.dayKey()
    return require("lockscreen.styles.base").dayKey()
end

---@param period string
---@return string 周期展示文案
local function periodLabel(period)
    local labels = { today = _("今日"), ["7d"] = _("最近 7 天"), ["30d"] = _("最近 30 天"), month = _("本月") }
    return labels[period] or labels["7d"]
end

---@param seconds number|nil 秒数
---@return string 本地化时长文案
local function duration(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return minutes >= 60 and T(_("%1小时%2分"), math.floor(minutes / 60), minutes % 60)
        or T(_("%1分钟"), minutes)
end

---@param cb fun(ok: boolean, err: any)
---@return table|nil 可取消的背景下载任务
function M.fetch(cb)
    return Background.ensure(function(bg)
        local Render = require("lockscreen.render")
        local w, h = Render.size()
        local margin = math.floor(w * 0.055)
        local inner_x = margin * 2
        local inner_w = w - inner_x * 2
        local bill = Context.bill()
        local summary = bill.summary
        local days_count = math.max(1, math.ceil((bill.end_ts - bill.start_ts) / 86400))
        local blocks = {
            { kind = "panel", x = margin, y = math.floor(h * 0.025), width = w - margin * 2, height = math.floor(h * 0.94) },
            { text = _("阅读账单"), x = inner_x, y = math.floor(h * 0.055), width = inner_w, size = 38, bold = true, box = false, align = "right" },
            { text = os.date("NO.%Y%m%d", bill.end_ts - 1), x = inner_x, y = math.floor(h * 0.075), width = inner_w / 2, size = 16, box = false },
            { text = periodLabel(bill.period) .. "  " .. os.date("%Y.%m.%d", bill.start_ts) .. " - " .. os.date("%Y.%m.%d", bill.end_ts - 1), x = inner_x, y = math.floor(h * 0.135), width = inner_w, size = 18, box = false },
            { kind = "rule", x = inner_x, y = math.floor(h * 0.185), width = inner_w },
            { text = duration(summary.total_seconds), x = inner_x, y = math.floor(h * 0.215), width = inner_w * 0.58, size = 42, bold = true, box = false },
            { text = T(_("阅读 %1 本 · %2 页"), summary.book_count, summary.pages), x = math.floor(inner_x + inner_w * 0.60), y = math.floor(h * 0.235), width = math.floor(inner_w * 0.40), size = 18, align = "right", box = false },
            { text = _("书单") .. " TOP 5", x = inner_x, y = math.floor(h * 0.305), width = inner_w, size = 19, bold = true, box = false },
            { kind = "rule", x = inner_x, y = math.floor(h * 0.345), width = inner_w },
        }
        local y = math.floor(h * 0.365)
        local row_h = math.floor(h * 0.067)
        if #bill.books == 0 then
            blocks[#blocks + 1] = { text = _("本周期暂无阅读记录"), x = inner_x, y = y, width = inner_w, size = 22, box = false }
        else
            for i, book in ipairs(bill.books) do
                blocks[#blocks + 1] = {
                    text = string.format("NO.%02d  %s\n%s · %.0f%% · %s", i,
                        book.title or book.stable_id, book.authors or "", book.percent, duration(book.seconds)),
                    x = inner_x, y = y, width = inner_w, size = 17, box = false,
                }
                y = y + row_h
            end
        end
        local chart_y = math.floor(h * 0.73)
        blocks[#blocks + 1] = { kind = "rule", x = inner_x, y = chart_y - 18, width = inner_w }
        blocks[#blocks + 1] = {
            text = _("日均") .. " " .. duration(summary.total_seconds / days_count),
            x = inner_x, y = chart_y, width = inner_w, size = 17, bold = true, box = false,
        }
        local daily = bill.days or {}
        local max_seconds = 1
        for _, day in ipairs(daily) do max_seconds = math.max(max_seconds, day.seconds or 0) end
        local chart_top = math.floor(h * 0.79)
        local chart_h = math.floor(h * 0.105)
        local gap = 2
        local bar_w = math.max(2, math.floor((inner_w - gap * math.max(0, #daily - 1)) / math.max(1, #daily)))
        for i, day in ipairs(daily) do
            blocks[#blocks + 1] = {
                kind = "vbar", x = inner_x + (i - 1) * (bar_w + gap), y = chart_top,
                width = bar_w, height = chart_h, value = (day.seconds or 0) / max_seconds,
            }
        end
        if #daily > 0 then
            blocks[#blocks + 1] = { text = daily[1].ymd:sub(6), x = inner_x, y = chart_top + chart_h + 5, width = math.floor(inner_w / 2), size = 13, box = false }
            blocks[#blocks + 1] = { text = daily[#daily].ymd:sub(6), x = math.floor(inner_x + inner_w / 2), y = chart_top + chart_h + 5, width = math.floor(inner_w / 2), size = 13, align = "right", box = false }
        end
        local ok, err = Render.write(M.path(), bg, blocks)
        cb(ok, err)
    end)
end

return M
