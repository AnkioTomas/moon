--[[--
主体：阅读统计三卡。

@module koplugin.book.ui.desktop.home.components.stats
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local Surface = require("ui.components.surface")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {
    id = "stats",
    label = _("阅读统计"),
}

local function recordCard(width, value, label)
    local pad = UI.sz(8)
    local inner_w = math.max(1, width - pad * 2)
    local value_widget = TextWidget:new{
        text = tostring(value),
        face = UI.face("cfont", 15),
        max_width = inner_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local label_widget = TextWidget:new{
        text = label,
        face = UI.face("xx_smallinfofont", 11),
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local height = pad * 2 + value_widget:getSize().h + UI.sz(4) + label_widget:getSize().h
    local card = Surface.card(CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = height - pad * 2 },
        VerticalGroup:new{
            align = "center",
            value_widget,
            VerticalSpan:new{ width = UI.sz(4) },
            label_widget,
        },
    }, {
        width = width,
        height = height,
        padding = pad,
        shadow = true,
    })
    return card, height
end

---@param ctx table
---@param state table
---@param opts table
---@return table
function M.build(ctx, state, opts)
    local w = opts.width
    local stats = state.stats or {}
    local gap = UI.sz(8)
    local items = {
        { value = T(_("%1天"), stats.streak or 0), label = _("连续阅读") },
        { value = stats.total_text or "—", label = _("总阅读") },
        { value = stats.today_text or "—", label = _("今日阅读") },
    }
    local card_w = math.floor((w - gap * (#items - 1)) / #items)
    local row = HorizontalGroup:new{ align = "center" }
    local row_h = 0
    for i, item in ipairs(items) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        local card, card_h = recordCard(card_w, item.value, item.label)
        row_h = math.max(row_h, card_h)
        table.insert(row, card)
    end
    return { widget = row, height = row_h }
end

return M
