--[[--
锁屏主体公共辅助：日期桶、章节文案、时长、空态。

书籍头部 / 封面 / 进度条已迁到 ui.components.bookinfo，本文件不再自造。
色值与 ui.components.bookui 对齐（COLOR_GRAY_*），DSL 块不依赖 Device。

@module koplugin.book.lockscreen.components.util
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local Blitbuffer = require("ffi/blitbuffer")

local U = {}

-- 与 UI.muted / dim / rule / surface 同源，避免 DSL 主体为取色去拉 Device。
U.MUTED = Blitbuffer.COLOR_GRAY_3
U.DIM = Blitbuffer.COLOR_GRAY_4
U.RULE = Blitbuffer.COLOR_GRAY_5
U.SURFACE = Blitbuffer.COLOR_GRAY_E
U.FALLBACK_MESSAGE = "读书不觉已春深，一寸光阴一寸金。"

--- 取所在自然日 00:00:00 的时间戳（本地时区）。
---@param ts number|nil 缺省用当前时间
---@return number
function U.dayStart(ts)
    local t = os.date("*t", ts or os.time())
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

--- 把按天统计行铺成 [start_ts, end_ts) 内逐日连续的桶，缺失日补零。
--- 游标固定取当日 12 点推进，绕开夏令时切换日只有 23 小时导致的跳日。
---@param rows table[]|nil 每行含 ymd / seconds / pages
---@param start_ts number
---@param end_ts number
---@return table[] 每项 { key, label, seconds, pages }
function U.dayBuckets(rows, start_ts, end_ts)
    local by_ymd = {}
    for _, row in ipairs(rows or {}) do
        if type(row.ymd) == "string" then by_ymd[row.ymd] = row end
    end
    local buckets = {}
    local t = os.date("*t", start_ts)
    local cursor = os.time{ year = t.year, month = t.month, day = t.day, hour = 12 }
    while cursor < end_ts do
        local ymd = os.date("%Y-%m-%d", cursor)
        local row = by_ymd[ymd]
        buckets[#buckets + 1] = {
            key = ymd, label = ymd:sub(6),
            seconds = row and (tonumber(row.seconds) or 0) or 0,
            pages = row and (tonumber(row.pages) or 0) or 0,
        }
        local next_day = os.date("*t", cursor)
        cursor = os.time{
            year = next_day.year, month = next_day.month,
            day = next_day.day + 1, hour = 12,
        }
    end
    return buckets
end

--- 去掉中英文常见章节前缀，让卡片标题保留真正的章节名。
---@param title string|nil
---@return string
function U.cleanChapterTitle(title)
    if type(title) ~= "string" then
        return ""
    end
    local cleaned = title
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :gsub("^第%d+章[:：%s]*", "")
        :gsub("^[Cc]hapter%s+%d+[:%.%s]*", "")
        :gsub("^[Cc]h%.%s*%d+[:%.%s]*", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    return cleaned
end

--- 将秒数格式化为适合锁屏宽度的分钟/小时文案。
---@param seconds number|nil
---@return string
function U.duration(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return minutes >= 60 and T(_("%1 小时 %2 分钟"), math.floor(minutes / 60), minutes % 60)
        or T(_("%1 分钟"), minutes)
end

--- 返回清洗后的章节名；没有章节名时显示章节序号或“阅读中”。
---@param book table
---@return string
function U.chapterLine(book)
    if book.chapter_title and book.chapter_title ~= "" then
        local cleaned = U.cleanChapterTitle(book.chapter_title)
        if cleaned ~= "" then
            return cleaned
        end
        return book.chapter_title
    end
    if book.chapter_count and book.chapter_count > 0 then
        return T(_("第 %1 / %2 章"), book.chapter_idx or 1, book.chapter_count)
    end
    return _("阅读中")
end

--- 返回统一的进度百分比和页数文案。
---@param book table
---@return number, string
function U.progress(book)
    local percent = math.max(0, math.min(100, tonumber(book.percent) or 0))
    local total = tonumber(book.total_pages) or 0
    local pages = total > 0 and string.format("%d / %d 页", tonumber(book.page) or 0, total)
        or _("页数暂无")
    return percent, pages
end

--- 生成主体没有数据时使用的空态白卡（纯 DSL，不拉 UI 树）。
---@param rect table
---@param title string
---@param message string
---@return table[]
function U.emptyBlocks(rect, title, message)
    return {
        {
            kind = "panel", x = rect.x, y = rect.y, width = rect.w, height = rect.h,
            radius = rect.radius, shadow = 2, color = Blitbuffer.COLOR_WHITE,
        },
        {
            text = title, x = rect.text_x, y = rect.y + rect.pad,
            width = rect.text_w, size = 18, box = false, color = U.MUTED,
        },
        {
            kind = "rule", x = rect.text_x, y = rect.y + rect.pad + 28,
            width = rect.text_w, height = 1, color = U.RULE,
        },
        {
            text = message,
            x = rect.text_x, y = rect.y + math.floor(rect.h * 0.48),
            width = rect.text_w, size = 20, align = "center", box = false, color = U.MUTED,
        },
    }
end

return U
