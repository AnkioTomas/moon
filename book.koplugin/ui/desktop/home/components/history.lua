--[[--
主体：历史上的今天。年份是列，事件是正文，不把两者拼成一行字符串。

@module koplugin.book.ui.desktop.home.components.history
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UI = require("ui.components.bookui")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local LINES = 3
local YEAR_W = 40
local ROW_GAP = 4

---@class BookHomeHistory : BookHomeComponent
local M = {
    id = "history",
    label = _("历史上的今天"),
    icon = "history_edu",
}
setmetatable(M, require("ui.desktop.home.components.base"))
M.__index = M

function M:heightRange()
    return {
        min = UI.sz(70),
        preferred = UI.sz(88),
        max = UI.sz(112),
        grow = 0,
    }
end

---@param daily BookHomeDaily
---@return { year: string, title: string }[]
local function rows(daily)
    local history = daily.history
    local out = {}
    if type(history) == "table" then
        for i = 1, math.min(LINES, #history) do
            local row = history[i]
            out[i] = { year = row.year, title = row.title }
        end
    end
    if #out == 0 then out[1] = { year = "", title = "--" } end
    return out
end

---@param year string
---@param title string
---@param inner_w number
---@return table
---@return table
---@return table
---@return number
local function line(year, title, inner_w)
    local year_w = UI.sz(YEAR_W)
    local gap = UI.sz(8)
    local mark = TextWidget:new{
        text = year,
        face = UI.face("cfont", 12),
        max_width = year_w,
        fgcolor = UI.muted(),
    }
    local body = TextWidget:new{
        text = title,
        face = UI.face("cfont", 13),
        max_width = math.max(1, inner_w - year_w - gap),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local h = math.max(mark:getSize().h, body:getSize().h)
    return HorizontalGroup:new{
        align = "center",
        RightContainer:new{
            dimen = Geom:new{ w = year_w, h = h },
            mark,
        },
        HorizontalSpan:new{ width = gap },
        body,
    }, mark, body, h
end

---@param ctx BookDesktopCtx
---@param opts BookHomeBuildOpts
---@return table
function M:build(ctx, opts)
    local w = opts.width
    local total_h = opts.height
    local pad_x = UI.sz(10)
    local inner_w = math.max(1, w - pad_x * 2)
    local title = TextWidget:new{
        text = _("历史上的今天"),
        face = UI.face("cfont", 12),
        bold = true,
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local kids = { align = "left", title, VerticalSpan:new{ width = UI.sz(ROW_GAP) } }
    local marks, items = {}, {}
    local data = rows(self.home.daily or {})
    local row_h = 0
    for i = 1, LINES do
        if i > 1 then
            table.insert(kids, VerticalSpan:new{ width = UI.sz(ROW_GAP) })
        end
        local row = data[i] or { year = "", title = "" }
        local group, mark, body, h = line(row.year, row.title, inner_w)
        row_h = h
        marks[i] = mark
        items[i] = body
        table.insert(kids, group)
    end
    local inner_h = title:getSize().h + UI.sz(ROW_GAP)
        + LINES * row_h + (LINES - 1) * UI.sz(ROW_GAP)
    local pad_y = math.max(0, math.floor((total_h - inner_h) / 2))
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_y,
        padding_bottom = pad_y,
        margin = 0,
        dimen = Geom:new{ w = w, h = total_h },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            VerticalGroup:new(kids),
        },
    }
    self.marks = marks
    self.items = items
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = opts.y or 0, w = w, h = total_h }
    return { widget = widget, height = total_h }
end

function M:updateView()
    if not self.items then return end
    local data = rows(self.home.daily or {})
    for i = 1, LINES do
        local row = data[i] or { year = "", title = "" }
        self.marks[i]:setText(row.year)
        self.items[i]:setText(row.title)
    end
    require("ui/uimanager"):setDirty(self.desktop, "ui", self.region)
end

function M:onResume()
    self:updateView()
end

function M:onDestroy()
    self.marks = nil
    self.items = nil
    self.region = nil
    self.desktop = nil
end

return M
