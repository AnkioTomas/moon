--[[--
主体：历史上的今天。年份是列，事件是正文。自己读 online.myrl（http.cache）。

@module koplugin.book.ui.desktop.home.views.history
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Myrl = require("online.myrl")
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
---@field data { year: string, title: string }[]|nil
local M = {
    id = "history",
    label = _("历史上的今天"),
    icon = "history_edu",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

--- 从历史事件数据提取年份和标题，供固定行数布局使用。
---@param history { year: string, title: string }[]|nil
---@return { year: string, title: string }[]
local function rows(history)
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

--- 构建带序号或年份的单行内容，并返回可原地更新的文字控件。
---@param year string 历史事件发生年份的显示文字
---@param title string 显示标题
---@param inner_w number 扣除左右留白后的内容宽度，单位像素
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

--- 返回历史上的今天内容高度；不吃剩余空间。
---@param _ctx table|nil
---@param opts table|nil
---@return BookHomeHeightSpec
function M:heightRange(_ctx, opts)
    local inner_w = math.max(1, opts and opts.width or UI.sz(300))
    local title = TextWidget:new{
        text = _("历史上的今天"),
        face = UI.face("cfont", 12),
        bold = true,
        max_width = inner_w,
    }
    local row_h = select(4, line("0000", "--", inner_w))
    local gap = UI.sz(ROW_GAP)
    return { height = title:getSize().h + gap + LINES * row_h + (LINES - 1) * gap }
end

--- 构建历史上的今天列表，保存年份和标题控件供原地更新。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local total_h = opts.height
    local pad_x = 0
    local inner_w = w
    local title = TextWidget:new{
        text = _("历史上的今天"),
        face = UI.face("cfont", 12),
        bold = true,
        max_width = inner_w,
        fgcolor = UI.muted(),
    }
    local kids = { align = "left", title, VerticalSpan:new{ width = UI.sz(ROW_GAP) } }
    local marks, items = {}, {}
    local data = rows(self.data)
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
    local col = VerticalGroup:new(kids)
    local inner_h = title:getSize().h + UI.sz(ROW_GAP)
        + LINES * row_h + (LINES - 1) * UI.sz(ROW_GAP)
    local extra = math.max(0, total_h - inner_h)
    local pad_top = math.floor(extra / 2)
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_top,
        padding_bottom = extra - pad_top,
        margin = 0,
        col,
    }
    self.marks = marks
    self.items = items
    self.desktop = ctx.desktop
    self.region = Geom:new{ x = 0, y = opts.y or 0, w = w, h = total_h }
    return widget
end

--- 把当前历史事件写入已有年份和标题行并刷新内容区域。
---@return nil
function M:updateView()
    if not self.items then return end
    local data = rows(self.data)
    for i = 1, LINES do
        local row = data[i] or { year = "", title = "" }
        self.marks[i]:setText(row.year)
        self.items[i]:setText(row.title)
    end
    self:dirty("content")
end

--- 异步取得摸鱼日报中的历史事件，失败时保留已有数据。
---@param done fun(data:any, err:any) 数据加载回调；失败回退旧数据时仍按成功交付
---@return table|nil request 在线接口返回的取消句柄；同步缓存命中可能无句柄
function M:loadData(done)
    return Myrl:fetch({}, function(data, err)
        done(not err and data.history or self.data)
    end)
end

--- 仅在 Resume 阶段发起数据加载；数据变化后更新内容，取消的旧回调不再改写视图。
---@return nil
function M:pull()
    if not self.lifecycle:uiReady() then return end
    local previous = self.data
    self:load(function(ok)
        if ok and self.data ~= previous then
            self:updateView()
        end
    end)
end

--- 恢复显示时拉取历史事件。
---@return nil
function M:onResume()
    self:pull()
end

--- 清除历史事件的年份、标题控件和桌面引用。
---@return nil
function M:onDestroy()
    self.marks = nil
    self.items = nil
    self.region = nil
    self.desktop = nil
    self.data = nil
end

return M
