--[[--
主体：热点新闻。序号是列，标题是正文。自己读 online.myrl（http.cache）。

@module koplugin.book.ui.desktop.home.views.news
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Myrl = require("online.myrl")
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
---@field data string[]|nil
local M = {
    id = "news",
    label = _("热点新闻"),
    icon = "newspaper",
}
setmetatable(M, require("ui.desktop.home.views.base"))
M.__index = M

--- 返回当前组件的最小、首选和最大高度，供首页布局分配空间。
---@return BookHomeHeightRange range 首页布局使用的高度约束
function M:heightRange()
    return {
        min = UI.sz(78),
        preferred = UI.sz(96),
        max = UI.sz(120),
        grow = 0,
    }
end

--- 从日报数据提取供新闻列表显示的标题。
---@param news string[]|nil 日报新闻标题数组
---@return string[]
local function lines(news)
    local out = {}
    if type(news) == "table" then
        for i = 1, math.min(LINES, #news) do
            out[i] = news[i]
        end
    end
    if #out == 0 then out[1] = "--" end
    return out
end

--- 构建带序号或年份的单行内容，并返回可原地更新的文字控件。
---@param index string 子控件数组中的槽位索引，从 1 开始
---@param title string 显示标题
---@param inner_w number 扣除左右留白后的内容宽度，单位像素
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

--- 构建日报新闻标题及固定新闻行，保存文字控件供原地更新。
---@return table
function M:createWidget()
    local ctx, opts = self.ctx, self.opts
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
    local texts = lines(self.data)
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
    return widget
end

--- 把当前新闻数据写入已有行并刷新内容区域。
---@return nil
function M:updateView()
    if not self.items then return end
    local texts = lines(self.data)
    for i = 1, LINES do
        self.items[i]:setText(texts[i] or "")
    end
    self:dirty("content")
end

--- 异步取得摸鱼日报中的新闻，失败时保留已有新闻数据。
---@param done fun(data:any, err:any) 数据加载回调；失败回退旧数据时仍按成功交付
---@return table|nil request 在线接口返回的取消句柄；同步缓存命中可能无句柄
function M:loadData(done)
    return Myrl:fetch({}, function(data, err)
        done(not err and data.news or self.data)
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

--- 恢复显示时拉取新闻数据。
---@return nil
function M:onResume()
    self:pull()
end

--- 清除新闻文字控件和桌面引用。
---@return nil
function M:onDestroy()
    self.items = nil
    self.region = nil
    self.desktop = nil
    self.data = nil
end

return M
