--[[--
主体：热点新闻。序号是列，标题是正文。

@module koplugin.book.ui.desktop.home.components.news
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

local LINES = 4
local INDEX_W = 20
local ROW_GAP = 4

---@class BookHomeNews : BookHomeComponent
local M = {
    id = "news",
    label = _("热点新闻"),
    icon = "newspaper",
}
setmetatable(M, require("ui.desktop.home.components.base"))
M.__index = M

function M:heightRange()
    return {
        min = UI.sz(78),
        preferred = UI.sz(96),
        max = UI.sz(120),
        grow = 0,
    }
end

---@param daily BookHomeDaily
---@return string[]
local function lines(daily)
    local news = daily.news
    local out = {}
    if type(news) == "table" then
        for i = 1, math.min(LINES, #news) do
            out[i] = news[i]
        end
    end
    if #out == 0 then out[1] = "--" end
    return out
end

---@param index string
---@param title string
---@param inner_w number
---@return table
---@return table
---@return number
local function line(index, title, inner_w)
    local index_w = UI.sz(INDEX_W)
    local gap = UI.sz(8)
    local mark = TextWidget:new{
        text = index,
        face = UI.face("cfont", 12),
        max_width = index_w,
        fgcolor = UI.dim(),
    }
    local body = TextWidget:new{
        text = title,
        face = UI.face("cfont", 13),
        max_width = math.max(1, inner_w - index_w - gap),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local h = math.max(mark:getSize().h, body:getSize().h)
    return HorizontalGroup:new{
        align = "center",
        RightContainer:new{
            dimen = Geom:new{ w = index_w, h = h },
            mark,
        },
        HorizontalSpan:new{ width = gap },
        body,
    }, body, h
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
        text = _("热点新闻"),
        face = UI.face("cfont", 12),
        bold = true,
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local kids = { align = "left", title, VerticalSpan:new{ width = UI.sz(ROW_GAP) } }
    local items = {}
    local texts = lines(self.home.daily or {})
    local row_h = 0
    for i = 1, LINES do
        if i > 1 then
            table.insert(kids, VerticalSpan:new{ width = UI.sz(ROW_GAP) })
        end
        local group, body, h = line(string.format("%02d", i), texts[i] or "", inner_w)
        row_h = h
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
    self.items = items
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = opts.y or 0, w = w, h = total_h }
    return { widget = widget, height = total_h }
end

function M:updateView()
    if not self.items then return end
    local texts = lines(self.home.daily or {})
    for i = 1, LINES do
        self.items[i]:setText(texts[i] or "")
    end
    require("ui/uimanager"):setDirty(self.desktop, "ui", self.region)
end

function M:onResume()
    self:updateView()
end

function M:onDestroy()
    self.items = nil
    self.region = nil
    self.desktop = nil
end

return M
