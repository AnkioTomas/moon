--[[--
阅读统计锁屏。

对齐 DESIGN.md：白底浅卡、黑灰字阶、胶囊进度、KPI 层次分明。

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
            local card_h = math.floor(h * 0.78)
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
                    text = book.title, x = inner_x, y = math.floor(card_y + card_h * 0.14),
                    width = inner_w, size = 28, bold = true, box = false,
                },
                {
                    text = book.authors, x = inner_x, y = math.floor(card_y + card_h * 0.28),
                    width = inner_w, size = 16, box = false, color = MUTED,
                },
                {
                    text = string.format("%.0f%%", book.percent),
                    x = inner_x, y = math.floor(card_y + card_h * 0.40),
                    width = inner_w, size = 52, bold = true, box = false,
                },
                -- DESIGN：胶囊进度条，高约 8
                {
                    kind = "bar", x = inner_x, y = math.floor(card_y + card_h * 0.55),
                    width = inner_w, height = 8, value = book.percent / 100,
                },
                {
                    text = meta, x = inner_x, y = math.floor(card_y + card_h * 0.62),
                    width = inner_w, size = 15, box = false, color = DIM,
                },
                {
                    kind = "rule", x = inner_x, y = math.floor(card_y + card_h * 0.72),
                    width = inner_w, height = 1,
                },
                {
                    text = _("累计阅读"), x = inner_x, y = math.floor(card_y + card_h * 0.76),
                    width = inner_w, size = 13, box = false, color = MUTED,
                },
                {
                    text = duration(book.total_seconds),
                    x = inner_x, y = math.floor(card_y + card_h * 0.84),
                    width = inner_w, size = 22, bold = true, box = false,
                },
            }
        end

        local ok, err = Render.write(M.path(), bg, blocks)
        cb(ok, err)
    end)
end

return M
