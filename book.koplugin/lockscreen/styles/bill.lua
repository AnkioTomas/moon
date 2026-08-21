--[[--
阅读账单锁屏。

对齐 DESIGN.md：白底浅卡、字阶分明、书单平铺、柱图克制（今日按小时 / 周月按天）。

@module koplugin.book.lockscreen.styles.bill
--]]

local Background = require("lockscreen.background")
local Context = require("lockscreen.context")
local Paths = require("utils.paths")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local T = require("ffi/util").template

local M = { id = "bill", label = _("阅读账单"), local_render = true }

local MUTED = Blitbuffer.COLOR_GRAY_3
local DIM = Blitbuffer.COLOR_GRAY_4

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
        local margin = math.max(16, math.floor(w * 0.05))
        local radius = math.max(8, math.floor(w * 0.02))
        local pad = math.max(14, math.floor(w * 0.04))
        local card_x = margin
        local card_w = w - margin * 2
        local card_y = math.floor(h * 0.03)
        local card_h = math.floor(h * 0.94)
        local inner_x = card_x + pad
        local inner_w = card_w - pad * 2
        local bill = Context.bill()
        local summary = bill.summary
        local grain = bill.grain or "day"
        local buckets = bill.buckets or bill.days or {}
        -- 日均：按日历格数；时均：按今日已过小时（含当前小时）
        local avg_div
        if grain == "hour" then
            avg_div = math.max(1, (tonumber(os.date("%H")) or 0) + 1)
        else
            avg_div = math.max(1, #buckets)
        end

        local blocks = {
            {
                kind = "panel", x = card_x, y = card_y, width = card_w, height = card_h,
                radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
            },
            {
                text = _("阅读账单"), x = inner_x, y = card_y + pad,
                width = inner_w, size = 22, bold = true, box = false, align = "right",
            },
            {
                text = os.date("NO.%Y%m%d", bill.end_ts - 1),
                x = inner_x, y = card_y + pad + 4, width = inner_w / 2, size = 14, box = false, color = MUTED,
            },
            {
                text = periodLabel(bill.period) .. "  "
                    .. os.date("%Y.%m.%d", bill.start_ts) .. " - " .. os.date("%Y.%m.%d", bill.end_ts - 1),
                x = inner_x, y = math.floor(h * 0.12), width = inner_w, size = 15, box = false, color = MUTED,
            },
            { kind = "rule", x = inner_x, y = math.floor(h * 0.165), width = inner_w, height = 1 },
            -- KPI 主值
            {
                text = duration(summary.total_seconds),
                x = inner_x, y = math.floor(h * 0.19), width = inner_w * 0.58, size = 36, bold = true, box = false,
            },
            {
                text = T(_("阅读 %1 本 · %2 页"), summary.book_count, summary.pages),
                x = math.floor(inner_x + inner_w * 0.55), y = math.floor(h * 0.21),
                width = math.floor(inner_w * 0.45), size = 15, align = "right", box = false, color = MUTED,
            },
            {
                text = _("书单") .. " TOP 5",
                x = inner_x, y = math.floor(h * 0.29), width = inner_w, size = 16, bold = true, box = false,
            },
            { kind = "rule", x = inner_x, y = math.floor(h * 0.325), width = inner_w, height = 1 },
        }

        -- 书单：平铺行，不套卡（DESIGN：行用平铺）
        local y = math.floor(h * 0.345)
        local row_h = math.floor(h * 0.068)
        if #bill.books == 0 then
            blocks[#blocks + 1] = {
                text = _("本周期暂无阅读记录"),
                x = inner_x, y = y, width = inner_w, size = 18, box = false, color = MUTED,
            }
        else
            for i, book in ipairs(bill.books) do
                blocks[#blocks + 1] = {
                    text = string.format("NO.%02d  %s", i, book.title or book.stable_id),
                    x = inner_x, y = y, width = inner_w, size = 16, bold = true, box = false,
                }
                blocks[#blocks + 1] = {
                    text = string.format("%s · %.0f%% · %s",
                        book.authors or "", book.percent, duration(book.seconds)),
                    x = inner_x, y = y + math.floor(row_h * 0.42),
                    width = inner_w, size = 13, box = false, color = DIM,
                }
                y = y + row_h
            end
        end

        -- 柱状图：今日按小时，周/月按天（见 DESIGN.md「锁屏账单柱图」）
        local chart_y = math.floor(h * 0.72)
        local avg_label = grain == "hour" and _("时均") or _("日均")
        blocks[#blocks + 1] = { kind = "rule", x = inner_x, y = chart_y - 16, width = inner_w, height = 1 }
        blocks[#blocks + 1] = {
            text = avg_label .. " " .. duration(summary.total_seconds / avg_div),
            x = inner_x, y = chart_y, width = inner_w, size = 15, bold = true, box = false,
        }

        local max_seconds = 1
        for _, slot in ipairs(buckets) do
            max_seconds = math.max(max_seconds, slot.seconds or 0)
        end
        local n = #buckets
        local chart_top = math.floor(h * 0.775)
        local chart_h = math.floor(h * 0.11)
        local gap = math.max(2, math.floor(inner_w * 0.012))
        -- 柱宽上限：约内容宽 8%；24 小时会自然变细
        local bar_cap = math.max(4, math.floor(inner_w * 0.08))
        local bar_w = n > 0
            and math.max(3, math.min(bar_cap, math.floor((inner_w - gap * (n - 1)) / n)))
            or 3
        local chart_w = n > 0 and (bar_w * n + gap * (n - 1)) or 0
        local chart_x = inner_x + math.max(0, math.floor((inner_w - chart_w) / 2))
        local bar_radius = math.min(3, math.max(1, math.floor(bar_w / 3)))

        if n > 0 then
            blocks[#blocks + 1] = {
                kind = "rule", x = chart_x, y = chart_top + chart_h,
                width = chart_w, height = 1,
            }
        end
        for i, slot in ipairs(buckets) do
            local seconds = slot.seconds or 0
            local ratio = seconds / max_seconds
            if ratio > 0 then
                local filled = math.max(3, math.floor(chart_h * ratio + 0.5))
                blocks[#blocks + 1] = {
                    kind = "vbar",
                    x = chart_x + (i - 1) * (bar_w + gap),
                    y = chart_top + chart_h - filled,
                    width = bar_w,
                    height = filled,
                    value = 1,
                    radius = bar_radius,
                }
            end
        end
        if n > 0 then
            local label_y = chart_top + chart_h + 5
            -- ≤7 格逐柱标；小时 24 格与长周期只标首尾
            if n <= 7 then
                for i, slot in ipairs(buckets) do
                    blocks[#blocks + 1] = {
                        text = slot.label or slot.key or "",
                        x = chart_x + (i - 1) * (bar_w + gap),
                        y = label_y,
                        width = bar_w, size = 11, align = "center", box = false, color = DIM,
                    }
                end
            else
                blocks[#blocks + 1] = {
                    text = buckets[1].label or buckets[1].key or "",
                    x = chart_x, y = label_y,
                    width = math.floor(chart_w / 2), size = 12, box = false, color = DIM,
                }
                blocks[#blocks + 1] = {
                    text = buckets[n].label or buckets[n].key or "",
                    x = chart_x + math.floor(chart_w / 2), y = label_y,
                    width = math.floor(chart_w / 2), size = 12, align = "right", box = false, color = DIM,
                }
            end
        end

        local ok, err = Render.write(M.path(), bg, blocks)
        cb(ok, err)
    end)
end

return M
