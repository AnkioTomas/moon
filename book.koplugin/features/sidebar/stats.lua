--[[--
侧栏「统计」页：当前书在月读自己的 reading_stats 表里的汇总（不依赖 KOReader 统计插件），
打开本页时查一次；订阅文章不记统计，整页不出现（见 init.lua 的 AVAILABLE）。

@module koplugin.book.features.sidebar.stats
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Icon = require("ui.themes.widgets.icon")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local Catalog = require("book.catalog")
local _ = require("gettext")

local Stats = {}

--- 行图标，与 Stats.rows 的行序对应。
local ICONS = { "schedule", "timer", "calendar_month", "avg_time", "event", "history",
    "menu_book", "auto_stories", "avg_pace", "ink_highlighter", "edit_note", "flag" }

--- 当前书的身份；订阅文章（ephemeral 源）不记统计，这页没意义。
---@return BookIdentity|nil
local function identity()
    local cur = require("reader.session").current()
    local id = cur and cur.identity
    if id and not id.ephemeral then return id end
end

--- 当前书有可统计的身份。
---@return boolean
function Stats.available()
    return identity() ~= nil
end

--- 本机阅读库里的单书统计：时长、天数、日均、首次 / 最近阅读、页数、每页均时、划线与笔记数。
---@return table[] { label, value }
function Stats.rows()
    local id = identity()
    if not id then return {} end
    local StatsDB = require("book.stats_db")
    local sum = StatsDB.summaryByBook(id.source_id, id.stable_id)
    if sum.total_seconds <= 0 and sum.pages <= 0 then return {} end
    local daily = StatsDB.dailyByBook(id.source_id, id.stable_id, 100000)
    local days = #daily
    local remaining = require("reader.session").remainingSeconds()
    local finish = remaining and require("utils.forecast").finishDate(remaining, daily)
    local highlights, notes = 0, 0
    for _idx, row in ipairs(require("book.note_db").all(id.source_id, id.stable_id)) do
        for _i, item in ipairs(require("book.note.normalize").decode(row.payload) or {}) do
            if item.drawer then highlights = highlights + 1 end
            if item.note and item.note ~= "" then notes = notes + 1 end
        end
    end
    local function date(ts) return ts > 0 and os.date("%Y-%m-%d", ts) or "—" end
    return {
        { _("累计时长"), Catalog.formatDuration(sum.total_seconds) },
        { _("阅读时长"), Catalog.formatDuration(sum.local_seconds) },
        { _("阅读天数"), tostring(days) },
        { _("日均时长"), Catalog.formatDuration(days > 0 and sum.total_seconds / days or 0) },
        { _("首次阅读"), date(sum.first_read) },
        { _("最近阅读"), date(sum.last_read) },
        { _("总页数"), tostring(sum.total_pages) },
        { _("已读页数"), tostring(sum.pages) },
        { _("每页均时"), Catalog.formatDuration(sum.pages > 0 and sum.total_seconds / sum.pages or 0) },
        { _("划线"), tostring(highlights) },
        { _("笔记"), tostring(notes) },
        { _("预计读完"), finish and date(finish) or "—" },
    }
end

---@param width number
---@return table
function Stats.build(width)
    local t = Theme.current()
    local gap = Theme.px(t.space.sm)
    local icon_size = t.font.body + 4
    local icon_w = Theme.px(icon_size) + gap
    local avail = width - icon_w
    local col = VerticalGroup:new{ align = "left" }
    local rows = Stats.rows()
    if #rows == 0 then
        col[1] = Text.line("body", _("暂无阅读统计"), { width = width, color = t.color.muted })
        return col
    end
    for i, row in ipairs(rows) do
        -- 值列按实际宽度给（日期这类长值不折行），标签至少留四成，放不下才折行。
        local probe = Text.line("body", row[2])
        local value_w = math.min(probe:getSize().w + gap, math.floor(avail * 0.6))
        probe:free()
        local label_w = avail - value_w
        col[#col + 1] = HorizontalGroup:new{
            align = "center",
            Icon.widget{ name = ICONS[i] or "info", size = icon_size, color = Blitbuffer.Color8(t.color.muted) },
            HorizontalSpan:new{ width = gap },
            Text.box("body", row[1], label_w, { color = t.color.muted, transparent = true }),
            Text.box("body", row[2], value_w, { align = "right", transparent = true }),
        }
        col[#col + 1] = VerticalSpan:new{ width = gap }
    end
    return col
end

return Stats
