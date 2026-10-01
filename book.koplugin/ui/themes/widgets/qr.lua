--[[--
主题二维码弹窗（替代 QRMessage）：标题 + 二维码 + 可选说明，点任意处收起。

  +----------------------+
  | 扫码登录             |
  |      ▛▀▀▜ ▛▀▜        |
  |      ▙▄▄▟ ▙▄▟        |
  | 用微信扫一扫         |
  +----------------------+

  QR:new{ title = "…", text = url, caption = "…", close_callback = fn }:show()

二维码点阵仍由 KOReader QRWidget 生成（编码不属于主题）；边长取面板内宽与半屏高的较小值。

@module koplugin.book.ui.themes.widgets.qr
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local QRWidget = require("ui/widget/qrwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")

---@class BookThemeQR : BookThemeModal
---@field title string|nil
---@field text string 二维码内容
---@field caption string|nil
local QR = Modal:extend{
    close_on_tap = true,
    title = nil,
    text = nil,
    caption = nil,
}

function QR:init()
    Modal.init(self)
    local t = self.theme
    local inner = self:innerWidth()
    local size = math.min(inner, math.floor(self.dimen.h / 2))
    local body = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = inner, h = size },
            QRWidget:new{ text = self.text, width = size, height = size },
        },
    }
    if self.caption then
        body[#body + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) }
        body[#body + 1] = Text.box("caption", self.caption, inner,
            { align = "center", color = t.color.muted, bg = t.dialog.bg })
    end
    self:setDialog{ title = self.title, body = body }
end

return QR
