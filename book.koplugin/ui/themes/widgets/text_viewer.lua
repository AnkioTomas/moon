--[[--
主题文本查看（替代 TextViewer）：全屏，标题栏 + 分页正文 + 翻页条，不滚动。

  +-------------------------------+
  |           标题          [×]   |
  |-------------------------------|
  | 正文正文正文正文正文正文……    |
  | ……                            |
  | [<]        2 / 5         [>]  |
  +-------------------------------+

  TextViewer:new{ title = "日志", text = long_text }:show()

@module koplugin.book.ui.themes.widgets.text_viewer
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Theme = require("ui.themes.init")
local Box = require("ui.themes.widgets.box")
local Modal = require("ui.themes.widgets.modal")
local Pager = require("ui.themes.widgets.pager")
local Text = require("ui.themes.widgets.text")
local TitleBar = require("ui.themes.widgets.titlebar")

---@class BookThemeTextViewer : BookThemeModal
---@field title string|nil
---@field text string
---@field page integer
local TextViewer = Modal:extend{
    mask = false,
    title = nil,
    text = nil,
}

function TextViewer:init()
    Modal.init(self)
    local t = self.theme
    local w, h = self.dimen.w, self.dimen.h
    local pad = Theme.px(t.space.lg)
    self.bar = TitleBar.widget({
        width = w, title = self.title,
        right_icon = "close", right_callback = function() self:dismiss() end,
    })
    local body_h = h - self.bar:getSize().h - Theme.px(t.control.height) - pad * 2
    self.body = Text.box("body", self.text, w - pad * 2, { height = body_h })
    self.pages = math.max(1, math.ceil(self.body:getAllLineCount() / self.body:getVisLineCount()))
    self.page = 1
    self:rebuild()
end

function TextViewer:rebuild()
    local t = self.theme
    local w, h = self.dimen.w, self.dimen.h
    self:setPanel(Box:new{
        style = { bg = t.color.page },
        width = w,
        height = h,
        VerticalGroup:new{
            align = "center",
            self.bar,
            Box:new{ style = {}, padding = Theme.px(t.space.lg), self.body },
            Pager.widget({
                width = w,
                page = self.page,
                pages = self.pages,
                on_prev = function() self:turn(-1) end,
                on_next = function() self:turn(1) end,
            }),
        },
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
