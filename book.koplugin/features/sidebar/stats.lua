--[[--
侧栏「统计」页：当前书在 KOReader 阅读统计插件里的书籍信息（同其「书籍信息」页，去掉书名作者）。

数据直接取 ui.statistics:getBookStat（文案、时长格式随 KOReader 设置），打开本页时查一次；
统计插件未启用或本书未入库时整页不出现（见 init.lua 的 AVAILABLE）。

@module koplugin.book.features.sidebar.stats
--]]

require("l10n").apply()

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Icon = require("ui.themes.widgets.icon")
local Text = require("ui.themes.widgets.text")
local Theme = require("ui.themes")
local _ = require("gettext")

local Stats = {}

--- 行图标，按 getBookStat 去掉书名作者后的行序：总时长、阅读时长、天数、日均、开始、最后、
--- 页数、已读页、每页均时、高亮、笔记。
local ICONS = { "schedule", "timer", "calendar_month", "avg_time", "event", "history",
    "menu_book", "auto_stories", "avg_pace", "ink_highlighter", "edit_note" }

--- 统计插件可用且当前书已入库。
---@param ui table ReaderUI
---@return boolean
function Stats.available(ui)
    -- 订阅文章（ephemeral 源）不记统计，这页没意义。
    local cur = require("reader.session").current()
    if cur and cur.identity and cur.identity.ephemeral then return false end
    local stat = ui and ui.statistics
    return stat ~= nil and stat.isEnabled ~= nil and stat:isEnabled() and stat.id_curr_book ~= nil
end

--- 先把本次会话的页时长落库，再取书籍统计；去掉书名 / 作者两行和「读这本书的天数」的展开箭头。
---@param ui table ReaderUI
---@return table[] { label, value, separator }
function Stats.rows(ui)
    if not Stats.available(ui) then return {} end
    local stat = ui.statistics
    pcall(stat.insertDB, stat)
    local ok, kv = pcall(stat.getBookStat, stat, stat.id_curr_book)
    if not ok or type(kv) ~= "table" then return {} end
    local rows = {}
    for i = 3, #kv do
        local item = kv[i]
        -- 箭头是多字节字符，不能放进 [] 字符类
        local label = tostring(item[1] or ""):gsub("%s*▸$", ""):gsub("%s*◂$", "")
        rows[#rows + 1] = { label, tostring(item[2] or ""), item.separator }
    end
    return rows
end

---@param ui table ReaderUI
---@param width number
---@return table
function Stats.build(ui, width)
    local t = Theme.current()
    local gap = Theme.px(t.space.sm)
    local icon_size = t.font.body + 4
    local icon_w = Theme.px(icon_size) + gap
    local avail = width - icon_w
    local col = VerticalGroup:new{ align = "left" }
    local rows = Stats.rows(ui)
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
            Text.box("body", row[1], label_w, { color = t.color.muted }),
            Text.box("body", row[2], value_w, { align = "right" }),
        }
        col[#col + 1] = VerticalSpan:new{ width = gap }
        if row[3] and i < #rows then
            col[#col + 1] = LineWidget:new{
                dimen = Geom:new{ w = width, h = math.max(1, Theme.px(t.row.divider)) },
                background = Blitbuffer.Color8(t.color.muted),
            }
            col[#col + 1] = VerticalSpan:new{ width = gap }
        end
    end
    return col
end

return Stats
