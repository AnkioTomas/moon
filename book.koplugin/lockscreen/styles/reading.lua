--[[--
阅读统计锁屏。

对齐 DESIGN.md：白底浅卡、黑灰字阶、胶囊进度、近 7 日柱图。

@module koplugin.book.lockscreen.styles.reading
--]]

local Background = require("lockscreen.background")
local Context = require("lockscreen.context")
local Paths = require("utils.paths")
local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")
local T = require("ffi/util").template

local M = { id = "reading", label = _("阅读统计"), local_render = true }

local MUTED = Blitbuffer.COLOR_GRAY_3
local DIM = Blitbuffer.COLOR_GRAY_4

---@return string 阅读统计图片缓存路径
function M.path()
    return Paths.screensaverDir() .. "/reading.png"
end

---@return string 当前日期 YYYY-MM-DD
function M.dayKey()
    return require("lockscreen.styles.base").dayKey()
end

---@param seconds number|nil 秒数
---@return string 本地化时长文案
local function duration(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return minutes >= 60 and T(_("%1 小时 %2 分钟"), math.floor(minutes / 60), minutes % 60)
        or T(_("%1 分钟"), minutes)
end

--- 追加近 7 日柱图（契约同账单：底对齐、空档不画柱、≤7 逐柱标）。
---@param blocks table[]
---@param buckets table[]
---@param inner_x number
---@param inner_w number
---@param chart_top number
---@param chart_h number
local function appendDayChart(blocks, buckets, inner_x, inner_w, chart_top, chart_h)
    local max_seconds = 1
    for _, slot in ipairs(buckets) do
        max_seconds = math.max(max_seconds, slot.seconds or 0)
    end
    local n = #buckets
    local gap = math.max(2, math.floor(inner_w * 0.012))
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
        for i, slot in ipairs(buckets) do
            blocks[#blocks + 1] = {
                text = slot.label or slot.key or "",
                x = chart_x + (i - 1) * (bar_w + gap),
                y = label_y,
                width = bar_w, size = 11, align = "center", box = false, color = DIM,
            }
        end
    end
end

---@param cb fun(ok: boolean, err: any)
---@return table|nil 可取消的背景下载任务
function M.fetch(cb)
    return Background.ensure(function(bg)
        local Render = require("lockscreen.render")
        local w, h = Render.size()
        local margin = math.max(16, math.floor(w * 0.055))
        local radius = math.max(8, math.floor(w * 0.02))
        local pad = math.max(14, math.floor(w * 0.045))
        local card_x = margin
        local card_w = w - margin * 2
        local inner_x = card_x + pad
        local inner_w = card_w - pad * 2
        local book = Context.currentBook()
        local blocks

        if not book then
            local card_h = math.floor(h * 0.42)
            local card_y = math.floor((h - card_h) / 2)
            blocks = {
                {
                    kind = "panel", x = card_x, y = card_y, width = card_w, height = card_h,
                    radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
                },
                {
                    text = _("阅读统计"), x = inner_x, y = card_y + pad,
                    width = inner_w, size = 18, box = false, color = MUTED,
                },
                {
                    kind = "rule", x = inner_x, y = card_y + pad + 28,
                    width = inner_w, height = 1,
                },
                {
                    text = _("当前没有正在阅读的书籍"),
                    x = inner_x, y = card_y + math.floor(card_h * 0.48),
                    width = inner_w, size = 20, align = "center", box = false, color = MUTED,
                },
            }
        else
            local position = book.total_pages > 0
                and T(_("%1 / %2 页"), book.page, book.total_pages) or ""
            local chapter = book.chapter_count and book.chapter_count > 0
                and T(_("第 %1 / %2 章"), book.chapter_idx or 1, book.chapter_count) or ""
            local meta = table.concat({ position, chapter }, "  ·  ")
            local buckets = book.buckets or {}
            local week_seconds = 0
            for _, slot in ipairs(buckets) do
                week_seconds = week_seconds + (slot.seconds or 0)
            end
            local day_avg = week_seconds / math.max(1, #buckets)
            -- 抬高卡片：上半进度 + 下半柱图
            local card_h = math.floor(h * 0.90)
            local card_y = math.floor((h - card_h) / 2)
            blocks = {
                {
                    kind = "panel", x = card_x, y = card_y, width = card_w, height = card_h,
                    radius = radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
                },
                {
                    text = _("阅读统计"), x = inner_x, y = card_y + pad,
                    width = inner_w, size = 16, box = false, color = MUTED,
                },
                {
                    kind = "rule", x = inner_x, y = card_y + pad + 26,
                    width = inner_w, height = 1,
                },
                {
                    text = book.title, x = inner_x, y = math.floor(card_y + card_h * 0.10),
                    width = inner_w, size = 24, bold = true, box = false,
                },
                {
                    text = book.authors, x = inner_x, y = math.floor(card_y + card_h * 0.20),
                    width = inner_w, size = 15, box = false, color = MUTED,
                },
                {
                    text = string.format("%.0f%%", book.percent),
                    x = inner_x, y = math.floor(card_y + card_h * 0.28),
                    width = inner_w * 0.42, size = 40, bold = true, box = false,
                },
                {
                    text = _("累计阅读"),
                    x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.29),
                    width = math.floor(inner_w * 0.55), size = 13, align = "right", box = false, color = MUTED,
                },
                {
                    text = duration(book.total_seconds),
                    x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.34),
                    width = math.floor(inner_w * 0.55), size = 18, bold = true, align = "right", box = false,
                },
                -- DESIGN：胶囊进度条，高约 8
                {
                    kind = "bar", x = inner_x, y = math.floor(card_y + card_h * 0.44),
                    width = inner_w, height = 8, value = book.percent / 100,
                },
                {
                    text = meta, x = inner_x, y = math.floor(card_y + card_h * 0.49),
                    width = inner_w, size = 14, box = false, color = DIM,
                },
                {
                    kind = "rule", x = inner_x, y = math.floor(card_y + card_h * 0.56),
                    width = inner_w, height = 1,
                },
                {
                    text = _("最近 7 天"),
                    x = inner_x, y = math.floor(card_y + card_h * 0.59),
                    width = inner_w * 0.5, size = 15, bold = true, box = false,
                },
                {
                    text = _("日均") .. " " .. duration(day_avg),
                    x = math.floor(inner_x + inner_w * 0.45), y = math.floor(card_y + card_h * 0.59),
                    width = math.floor(inner_w * 0.55), size = 14, align = "right", box = false, color = MUTED,
                },
            }
            appendDayChart(
                blocks,
                buckets,
                inner_x,
                inner_w,
                math.floor(card_y + card_h * 0.68),
                math.floor(card_h * 0.20)
            )
        end

        local ok, err = Render.write(M.path(), bg, blocks)
        cb(ok, err)
    end)
end

return M
