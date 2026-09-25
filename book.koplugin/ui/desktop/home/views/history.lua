--[[--
主体：历史上的今天。年份是列，事件是正文。自己读 online.myrl（http.cache）。
热点新闻（news.lua）继承本模块，只换行数、标记列与数据字段。

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

local ROW_GAP = 4

---@class BookHomeHistory : BookHomeComponent
---@field data table[]|nil
---@field lines integer 固定行数
---@field mark_w number 标记列宽（未缩放像素）
---@field field string 摸鱼日报里的数据字段
local M = {
    id = "history",
    label = _("历史上的今天"),
    icon = "history_edu",
    lines = 3,
    mark_w = 40,
    field = "history",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

--- 第 i 行的标记与标题；数据不足时首行显示占位。
---@param i integer
---@return string mark
---@return string title
function M:row(i)
    local data = type(self.data) == "table" and self.data or {}
    local row = data[i]
    if row then return row.year, row.title end
    if i == 1 and #data == 0 then return "", "--" end
    return "", ""
end

--- 构建标记列 + 标题的单行内容，并返回可原地更新的文字控件。
---@param mark_text string
---@param title string 显示标题
---@param inner_w number 扣除左右留白后的内容宽度，单位像素
---@return table group
---@return table mark
---@return table body
---@return number h
function M:line(mark_text, title, inner_w)
    local mark_w = UI.sz(self.mark_w)
    local gap = UI.sz(8)
    local mark = TextWidget:new{
        text = mark_text,
        face = UI.face("cfont", 12),
        max_width = mark_w,
        fgcolor = self.markColor(),
    }
    local body = TextWidget:new{
        text = title,
        face = UI.face("cfont", 13),
        max_width = math.max(1, inner_w - mark_w - gap),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local h = math.max(mark:getSize().h, body:getSize().h)
    return HorizontalGroup:new{
        align = "center",
        RightContainer:new{
            dimen = Geom:new{ w = mark_w, h = h },
            mark,
        },
        HorizontalSpan:new{ width = gap },
        body,
    }, mark, body, h
end

M.markColor = UI.muted

--- 返回内容高度；不吃剩余空间。
---@param _ctx table|nil
---@param opts table|nil
---@return BookHomeHeightSpec
function M:heightRange(_ctx, opts)
    local inner_w = math.max(1, opts and opts.width or UI.sz(300))
    local title = TextWidget:new{
        text = self.label,
        face = UI.face("cfont", 12),
        bold = true,
        max_width = inner_w,
    }
    local probe, _mark, _body, row_h = self:line("0000", "--", inner_w)
    local gap = UI.sz(ROW_GAP)
    local total = title:getSize().h + gap + self.lines * row_h + (self.lines - 1) * gap
    if title.free then title:free() end
    if probe.free then probe:free() end
    return { height = total }
end

--- 构建固定行列表，保存标记和标题控件供原地更新。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
    local w = opts.width
    local total_h = opts.height
    local title = TextWidget:new{
        text = self.label,
        face = UI.face("cfont", 12),
        bold = true,
        max_width = w,
        fgcolor = UI.muted(),
    }
    local kids = { align = "left", title, VerticalSpan:new{ width = UI.sz(ROW_GAP) } }
    local marks, items = {}, {}
    local row_h = 0
    for i = 1, self.lines do
        if i > 1 then
            table.insert(kids, VerticalSpan:new{ width = UI.sz(ROW_GAP) })
        end
        local mark_text, title_text = self:row(i)
        local group, mark, body, h = self:line(mark_text, title_text, w)
        row_h = h
        marks[i] = mark
        items[i] = body
        table.insert(kids, group)
    end
    local col = VerticalGroup:new(kids)
    local inner_h = title:getSize().h + UI.sz(ROW_GAP)
        + self.lines * row_h + (self.lines - 1) * UI.sz(ROW_GAP)
    local extra = math.max(0, total_h - inner_h)
    local pad_top = math.floor(extra / 2)
    local widget = FrameContainer:new{
        bordersize = 0,
        padding = 0,
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

--- 把当前数据写入已有行并刷新内容区域。
function M:updateView()
    if not self.items then return end
    for i = 1, self.lines do
        local mark, title = self:row(i)
        self.marks[i]:setText(mark)
        self.items[i]:setText(title)
    end
    self:dirty("content")
end

--- 异步取得摸鱼日报中的本组件字段，失败时保留已有数据。
---@param done fun(data:any, err:any) 数据加载回调；失败回退旧数据时仍按成功交付
---@return table|nil request 在线接口返回的取消句柄；同步缓存命中可能无句柄
function M:loadData(done)
    return Myrl:fetch({}, function(data, err)
        done(not err and data[self.field] or self.data)
    end)
end

--- 仅在 Resume 阶段发起数据加载；数据变化后更新内容，取消的旧回调不再改写视图。
function M:pull()
    if not self.lifecycle:uiReady() then return end
    local previous = self.data
    self:load(function(ok)
        if ok and self.data ~= previous then
            self:updateView()
        end
    end)
end

--- 恢复显示时拉取数据。
function M:onResume()
    self:pull()
end

--- 清除标记、标题控件和桌面引用。
function M:onDestroy()
    self.marks = nil
    self.items = nil
    self.region = nil
    self.desktop = nil
    self.data = nil
end

return M
