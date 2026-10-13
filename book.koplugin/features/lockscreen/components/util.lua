--[[--
锁屏主体公共辅助：日期桶、章节文案、时长、空态。

封面和进度条用本文件的块，不引用桌面组件。
色值用 COLOR_GRAY_*，DSL 块不依赖 Device。

@module koplugin.book.features.lockscreen.components.util
--]]

local _ = require("gettext")
local T = require("ffi/util").template
local Blitbuffer = require("ffi/blitbuffer")

local U = {}

-- 灰度与主题 color 令牌同一套数值，避免 DSL 主体为取色去拉 Device。
U.MUTED = Blitbuffer.COLOR_GRAY_3
U.DIM = Blitbuffer.COLOR_GRAY_4
U.RULE = Blitbuffer.COLOR_GRAY_5
-- 进度条 / 柱图的空轨道，同主题 progress.track（0xDD）。COLOR_GRAY_N 是 0xNN，数字越小越黑。
U.TRACK = Blitbuffer.COLOR_GRAY_D
U.FALLBACK_MESSAGE = "读书不觉已春深，一寸光阴一寸金。"
--- 插件根目录下的 logo.png（账单 / 票根页眉共用）。
U.LOGO_PATH = (debug.getinfo(1, "S").source:match("^@(.+)/features/lockscreen/components/[^/]+$") or "") .. "/logo.png"

--- 取所在自然日 00:00:00 的时间戳（本地时区）。
---@param ts number|nil 缺省用当前时间
---@return number
function U.dayStart(ts)
    local t = os.date("*t", ts or os.time())
    ---@cast t osdate
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
    for _idx, row in ipairs(rows or {}) do
        if type(row.ymd) == "string" then by_ymd[row.ymd] = row end
    end
    local buckets = {}
    local t = os.date("*t", start_ts)
    local cursor = os.time{ year = t.year, month = t.month, day = t.day, hour = 12 }
    while cursor < end_ts do
        local ymd = os.date("%Y-%m-%d", cursor)
        ---@cast ymd string
        local row = by_ymd[ymd]
        buckets[#buckets + 1] = {
            key = ymd, label = ymd:sub(6),
            seconds = row and (tonumber(row.seconds) or 0) or 0,
            pages = row and (tonumber(row.pages) or 0) or 0,
        }
        local next_day = os.date("*t", cursor)
        ---@cast next_day osdate
        cursor = os.time{
            year = next_day.year, month = next_day.month,
            day = next_day.day + 1, hour = 12,
        }
    end
    return buckets
end

--- 将秒数格式化为适合锁屏宽度的分钟/小时文案。
---@param seconds number|nil
---@return string
function U.duration(seconds)
    local minutes = math.floor((tonumber(seconds) or 0) / 60)
    return minutes >= 60 and T(_("%1 小时 %2 分钟"), math.floor(minutes / 60), minutes % 60)
        or T(_("%1 分钟"), minutes)
end

--- 返回章节名；没有章节名时显示章节序号或“阅读中”。
---@param book table
---@return string
function U.chapterLine(book)
    if book.chapter_title and book.chapter_title ~= "" then
        return book.chapter_title
    end
    if book.chapter_count and book.chapter_count > 0 then
        return T(_("第 %1 / %2 章"), book.chapter_idx or 1, book.chapter_count)
    end
    return _("阅读中")
end

--- 书卡文字头：书名（粗）、作者、副标题自上而下按实测行高堆叠，每行压成单行；
--- 长书名折行或字体行高变化都不会压住下一行。空行跳过。
---@param book table
---@param subtitle string|nil
---@param x number
---@param y number
---@param width number
---@return table[] blocks
---@return number bottom 最后一行之下的 y
function U.bookHead(book, subtitle, x, y, width)
    local lines = {
        { text = book.title, size = 18, min = 15, bold = true },
        { text = book.authors, size = 14, min = 13, color = U.MUTED },
        { text = subtitle, size = 14, min = 13, color = U.MUTED },
    }
    local blocks = {}
    for _idx, line in ipairs(lines) do
        if line.text and line.text ~= "" then
            local block, h = U.fitLine(line.text, x, y, width, line.size, line.min, line.bold)
            block.color = line.color
            blocks[#blocks + 1] = block
            y = y + h + 4
        end
    end
    return blocks, y
end

--- 单行文字块：放不下先缩字号（不小于 min_size），再截断；返回块与实测行高。
---@param text string
---@param x number
---@param y number
---@param width number
---@param size number
---@param min_size number
---@param bold boolean|nil
---@return table block
---@return number h
function U.fitLine(text, x, y, width, size, min_size, bold)
    local measure = require("features.lockscreen.render").measureText
    local function fit(s, w, sz) return measure(s, w, sz, bold) end
    local fitted, fitted_size = require("features.lockscreen.title").fitSingleLine(text, width, size, min_size, fit)
    return {
        text = fitted, x = x, y = y, width = width, size = fitted_size, bold = bold, box = false,
    }, fit(fitted, width, fitted_size)
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

--- 追加票据式虚线。
---@param blocks table[]
---@param x number
---@param y number
---@param width number
---@param dash number 单段长度
---@param step number 段起点间距（含间隙）
function U.appendDashes(blocks, x, y, width, dash, step)
    local right = x + width
    while x < right do
        blocks[#blocks + 1] = {
            kind = "rule", x = x, y = y, width = math.min(dash, right - x),
            height = 1, color = U.DIM,
        }
        x = x + step
    end
end

--- 按种子串生成纯装饰条码，不冒充可扫描编码。
---@param blocks table[]
---@param x number
---@param y number
---@param width number
---@param height number
---@param seed string 空串时按字节 1 处理
---@param gap_every number 每隔几根留一次空
function U.appendBarcode(blocks, x, y, width, height, seed, gap_every)
    local right, i = x + width, 1
    while x < right do
        local byte = seed:byte((i - 1) % #seed + 1) or 1
        local bar = 1 + byte % 3
        if i % gap_every ~= 0 then
            blocks[#blocks + 1] = {
                kind = "vbar", x = x, y = y, width = math.min(bar, right - x),
                height = height, value = 1, color = Blitbuffer.COLOR_BLACK,
            }
        end
        x = x + bar + 1 + byte % 2
        i = i + 1
    end
end

--- 在票面上下边缘切出连续齿口。
---@param blocks table[]
---@param x number
---@param y number
---@param width number
---@param height number
---@param radius number
function U.appendCutouts(blocks, x, y, width, height, radius)
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
            width = rect.text_w, size = 20, bold = true, box = false,
        },
        {
            kind = "rule", x = rect.text_x, y = rect.y + rect.pad + 28,
            width = rect.text_w, height = 1, color = U.RULE,
        },
        {
            text = message,
            x = rect.text_x, y = rect.y + math.floor(rect.h * 0.48),
            width = rect.text_w, size = 16, align = "center", box = false, color = U.MUTED,
        },
    }
end

--- 本地封面图；没有缓存文件时用桌面同款生成封面（书名取色 + 竖排书名 + 作者）。
--- 生成封面是 widget 块，由 render 画完统一 free。
---@param book table|nil
---@return table
function U.coverBlock(book, x, y, w, h)
    local file = type(book) == "table" and book.cover or nil
    if type(file) == "string" and file ~= "" then
        return {
            kind = "image", file = file, x = x, y = y, width = w, height = h, scale_factor = 0,
        }
    end
    local widget = require("ui.widgets.plain_cover"):new{
        title = book and book.title or "",
        author = book and book.authors or "",
        width = w,
        height = h,
    }
    return { kind = "widget", widget = widget, x = x, y = y, width = w, height = h }
end

--- 百分比文案：不足 10% 保留一位小数，免得刚开读一直显示 0%。
---@param percent number|nil
---@return string
function U.percentText(percent)
    local pct = math.max(0, math.min(100, tonumber(percent) or 0))
    local text = pct >= 10 and tostring(math.floor(pct)) or string.format("%.1f", pct):gsub("%.0$", "")
    return text .. "%"
end

--- 横向进度：浅灰轨 + 黑色填充。高度固定 6。
---@return table[], number
function U.progressBlocks(x, y, width, percent)
    local h = 6
    local pct = math.max(0, math.min(100, tonumber(percent) or 0))
    local blocks = {
        { kind = "rule", x = x, y = y, width = width, height = h, color = U.TRACK },
    }
    local fill = math.floor(width * pct / 100)
    if fill > 0 then
        blocks[#blocks + 1] = {
            kind = "rule", x = x, y = y, width = fill, height = h, color = Blitbuffer.COLOR_BLACK,
        }
    end
    return blocks, h
end

return U
