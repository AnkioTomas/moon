--[[--
阅读统计锁屏。

@module koplugin.book.lockscreen.styles.reading
--]]

local Background = require("lockscreen.background")
local Context = require("lockscreen.context")
local Paths = require("utils.paths")
local _ = require("gettext")
local T = require("ffi/util").template

local M = { id = "reading", label = _("阅读统计"), local_render = true }

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
        local margin = math.floor(w * 0.07)
        local book = Context.currentBook()
        local blocks
        if not book then
            blocks = {
                { kind = "panel", x = margin, y = math.floor(h * 0.07), width = w - margin * 2, height = math.floor(h * 0.5) },
                { text = _("阅读统计"), x = margin * 2, y = math.floor(h * 0.11), width = w - margin * 4, size = 38, bold = true, box = false },
                { text = _("当前没有正在阅读的书籍"), x = margin * 2, y = math.floor(h * 0.25), width = w - margin * 4, size = 24, box = false },
            }
        else
            local position = book.total_pages > 0
                and T(_("%1 / %2 页"), book.page, book.total_pages) or ""
            local chapter = book.chapter_count and book.chapter_count > 0
                and T(_("第 %1 / %2 章"), book.chapter_idx or 1, book.chapter_count) or ""
            blocks = {
                { kind = "panel", x = margin, y = math.floor(h * 0.055), width = w - margin * 2, height = math.floor(h * 0.78) },
                { text = _("阅读统计"), x = margin * 2, y = math.floor(h * 0.09), width = w - margin * 4, size = 26, bold = true, box = false },
                { kind = "rule", x = margin * 2, y = math.floor(h * 0.145), width = w - margin * 4 },
                { text = book.title, x = margin * 2, y = math.floor(h * 0.19), width = w - margin * 4, size = 38, bold = true, box = false },
                { text = book.authors, x = margin * 2, y = math.floor(h * 0.30), width = w - margin * 4, size = 21, box = false },
                { text = string.format("%.0f%%", book.percent), x = margin * 2, y = math.floor(h * 0.40), width = w - margin * 4, size = 64, bold = true, box = false },
                { kind = "bar", x = margin * 2, y = math.floor(h * 0.52), width = w - margin * 4, height = 14, value = book.percent / 100 },
                { text = table.concat({ position, chapter }, "  "), x = margin * 2, y = math.floor(h * 0.59), width = w - margin * 4, size = 21, box = false },
                { kind = "rule", x = margin * 2, y = math.floor(h * 0.67), width = w - margin * 4 },
                { text = _("累计阅读") .. "\n" .. duration(book.total_seconds), x = margin * 2, y = math.floor(h * 0.71), width = w - margin * 4, size = 22, bold = true, box = false },
            }
        end
        local ok, err = Render.write(M.path(), bg, blocks)
        cb(ok, err)
    end)
end

return M
