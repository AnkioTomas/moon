--[[--
主体：历史上的今天。年份是列，事件是正文。读 online.myrl。
热点新闻（news.lua）继承本模块，只换行数、标记列与数据字段。

@module koplugin.book.desktop.pages.home.history
--]]

local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Myrl = require("online.myrl")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

---@class BookHomeHistory : BookHomeComponent
---@field data table[]|nil
---@field lines integer 固定行数
---@field mark_sample string 标记列最宽的样例文字，列宽按它实测
---@field field string 摸鱼日报里的数据字段
---@field mark_color string 标记列颜色令牌名（color.*）
local M = {
    id = "history",
    label = _("历史上的今天"),
    icon = "history_edu",
    lines = 3,
    mark_sample = "0000",
    field = "history",
    mark_color = "muted",
}
setmetatable(M, require("desktop.pages.home.base"))
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
---@param inner_w number 内容宽度，单位像素
---@return table group
---@return table mark
---@return table body
function M:line(mark_text, title, inner_w)
    local t = Theme.current()
    local sample = Text.line("caption", self.mark_sample)
    local mark_w, gap = sample:getSize().w, Theme.px(t.space.sm)
    sample:free()
    local mark = Text.line("caption", mark_text, { width = mark_w, color = t.color[self.mark_color] })
    local body = Text.line("body", title, { width = math.max(1, inner_w - mark_w - gap) })
    local h = math.max(mark:getSize().h, body:getSize().h)
    return HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = mark_w, h = h }, mark },
        HorizontalSpan:new{ width = gap },
        body,
    }, mark, body
end

--- 标题 + 固定行列表，另返回各行标记 / 正文控件供原地更新。
---@param w number 内容宽度
---@return table col
---@return table[] marks
---@return table[] items
function M:column(w)
    local t = Theme.current()
    local gap = Theme.px(t.space.xs)
    local col = VerticalGroup:new{
        align = "left",
        Text.line("caption", self.label, { width = w, color = t.color.muted, bold = true }),
    }
    local marks, items = {}, {}
    for i = 1, self.lines do
        local mark_text, title_text = self:row(i)
        local group
        group, marks[i], items[i] = self:line(mark_text, title_text, w)
        col[#col + 1] = VerticalSpan:new{ width = gap }
        col[#col + 1] = group
    end
    return col, marks, items
end

--- 返回内容高度；不吃剩余空间。
---@param _ctx table|nil
---@param opts table|nil
---@return BookHomeHeightSpec
function M:heightRange(_ctx, opts)
    local col = self:column(opts and opts.width or Theme.px(300))
    local h = col:getSize().h
    col:free()
    return { height = h }
end

---@return table
function M:createWidget()
    local w, h = self.opts.width, self.opts.height
    local col
    col, self.marks, self.items = self:column(w)
    -- 行宽随文字：居中会让整列漂离页边，和其它组件的左边缘对不齐。
    return LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, col }
end

--- 把当前数据写入已有行；所有行都未变时不刷新。
function M:paint()
    if not self.items then return end
    local changed = false
    for i = 1, self.lines do
        local mark, title = self:row(i)
        if self.marks[i].text ~= mark or self.items[i].text ~= title then
            changed = true
            self.marks[i]:setText(mark)
            self.items[i]:setText(title)
        end
    end
    if changed then self:dirty() end
end

--- 先画已有日报字段，再订阅；过期才入队。
function M:onActivate()
    local cur = Myrl:current()
    self.data = cur and cur[self.field] or self.data
    self:paint()
    self._on_daily = function(data, err)
        local rows = not err and data and data[self.field]
        if not rows or rows == self.data then return end
        self.data = rows
        self:paint()
    end
    Myrl:watch(self._on_daily)
    Myrl:ensure()
end

function M:onDeactivate()
    Myrl:unwatch(self._on_daily)
    self._on_daily = nil
end

function M:onDestroy()
    self.marks = nil
    self.items = nil
end

return M
