--[[--
主题文本查看（替代 TextViewer）：标题栏 + 分页正文 + 翻页条，不滚动。
两种风格：缺省全屏；``fullscreen = false`` 为居中弹窗卡片（宽度同其它弹窗，高度随内容、最高 90% 屏高，
超出分页），带遮罩，点卡片外关闭。

  +-------------------------------+
  |           标题          [×]   |
  |-------------------------------|
  | 正文正文正文正文正文正文……    |
  | ……                            |
  | [<]        2 / 5         [>]  |
  +-------------------------------+

  TextViewer:new{ title = "日志", text = long_text }:show()
  TextViewer:new{ title = "李善德", text = detail, fullscreen = false }:show()
  TextViewer:new{ title = "日志", text = long_text, buttons = {
      { text = "稍后", callback = function() end },
      { text = "安装", variant = "primary", callback = function() end },
  } }:show()

@module koplugin.book.ui.themes.widgets.text_viewer
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")

---@class BookThemeTextViewer : BookThemeModal
---@field title string|nil
---@field text string
---@field fullscreen boolean 全屏页（缺省）；false 为居中弹窗卡片
---@field page integer
---@field pages integer
---@field content_w integer 内容区宽（物理像素，已扣卡片边框）
---@field content_h integer 内容区高
---@field frame integer 卡片边框宽；全屏为 0
---@field body_h integer 正文区高度（物理像素）
---@field pager_h integer 翻页条高度（物理像素）
---@field fill integer 正文下方补的空白（全屏把内容撑满屏高；卡片为 0）
---@field buttons table[]|nil 底栏按钮 { text, variant, callback }；缺省只有标题栏关闭
local TextViewer = Modal:extend{
    mask = false,
    fullscreen = true,
    title = nil,
    text = nil,
    buttons = nil,
}

--- 卡片最高占屏高的比例。
local CARD_MAX_HEIGHT = 0.9

function TextViewer:init()
    if not self.fullscreen then self.mask = true end
    Modal.init(self)
    local t = self.theme
    self.frame = self.fullscreen and 0 or Theme.px(t.dialog.border or 0)
    local outer_w = self.fullscreen and self.dimen.w or Modal.dialogWidth()
    local outer_h = self.fullscreen and self.dimen.h or math.floor(self.dimen.h * CARD_MAX_HEIGHT)
    self.content_w = outer_w - self.frame * 2
    self.content_h = outer_h - self.frame * 2
    local w, h = self.content_w, self.content_h
    local pad = Theme.px(t.space.lg)
    self.bar = TitleBar.widget({
        width = w, title = self.title,
        right_icon = "close", right_callback = function() self:dismiss() end,
    })
    local button_h = 0
    if self.buttons and #self.buttons > 0 then
        button_h = pad * 2 + Theme.px(t.control.height)
    end
    self.pager_h = Theme.px(t.control.height)
    self.body_h = math.max(1, h - self.bar:getSize().h - self.pager_h - pad * 2 - button_h)
    self.body = Text.box("body", self.text, w - pad * 2, { height = self.body_h })
    self.pages = math.max(1, math.ceil(self.body:getAllLineCount() / self.body:getVisLineCount()))
    self.page = 1
    -- 不足一页时 TextBoxWidget 把高度压到实际行数，单页也不显示翻页条：空出的高度
    -- 全屏补成空白（Box 会把整组居中，不补正文就浮在屏幕中间），卡片直接收掉。
    self.fill = self.body_h - self.body:getSize().h
    if self.pages == 1 then self.fill = self.fill + self.pager_h end
    if not self.fullscreen then
        self.content_h = self.content_h - self.fill
        self.fill = 0
    end
    self:rebuild()
end

function TextViewer:rebuild()
    local t = self.theme
    local w = self.content_w
    local pad = Theme.px(t.space.lg)
    local kids = {
        align = "center",
        self.bar,
        Box:new{ style = {}, padding = pad, self.body },
        VerticalSpan:new{ width = self.fill },
    }
    if self.pages > 1 then
        kids[#kids + 1] = Pager.widget({
            width = w,
            page = self.page,
            pages = self.pages,
            on_prev = function() self:turn(-1) end,
            on_next = function() self:turn(1) end,
        })
    end
    if self.buttons and #self.buttons > 0 then
        kids[#kids + 1] = VerticalSpan:new{ width = pad }
        kids[#kids + 1] = self:buttonRow(self.buttons, w - pad * 2)
        kids[#kids + 1] = VerticalSpan:new{ width = pad }
    end
    self:setPanel(Box:new{
        style = self.fullscreen and { bg = t.color.page } or t.dialog,
        width = w + self.frame * 2,
        height = self.content_h + self.frame * 2,
        VerticalGroup:new(kids),
    })
end

--- 前后翻一页；TextBoxWidget 自己按可见行数滚动。
---@param dir integer 1 或 -1
function TextViewer:turn(dir)
    if dir > 0 then self.body:scrollDown() else self.body:scrollUp() end
    self.page = math.max(1, math.min(self.pages, self.page + dir))
    self:rebuild()
    UIManager:setDirty(self, "ui")
end

return TextViewer
