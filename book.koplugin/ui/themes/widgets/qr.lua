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
local Device = require("device")
local Geom = require("ui/geometry")
local QRWidget = require("ui/widget/qrwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Theme = require("ui.themes")
local Modal = require("ui.themes.widgets.modal")
local Text = require("ui.themes.widgets.text")
local _ = require("gettext")

---@class BookThemeQR : BookThemeModal
---@field title string|nil
---@field text string|nil 二维码内容
---@field image BlitBuffer|nil 官方返回的二维码位图，与 text 二选一
---@field actions table[]|nil
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
    local code = self.image and require("ui/widget/imagewidget"):new{
        image = self.image, width = size, height = size, scale_factor = 0,
    } or QRWidget:new{ text = self.text, width = size, height = size }
    local body = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = inner, h = size },
            code,
        },
    }
    if self.caption then
        body[#body + 1] = VerticalSpan:new{ width = Theme.px(t.space.md) }
        body[#body + 1] = Text.box("caption", self.caption, inner,
            { align = "center", color = t.color.muted, bg = t.dialog.bg })
    end
    local buttons = {}
    for _idx, action in ipairs(self.actions or {}) do buttons[#buttons + 1] = action end
    if self.text and self.text:match("^https?://") and (not Device:hasEinkScreen() or Device:isSDL()) and Device:canOpenLink() then
        buttons[#buttons + 1] = { text = _("在本机打开"), variant = "primary", callback = function()
            if not Device:openLink(self.text) then
                require("ui.themes.widgets.toast"):new{ text = _("无法打开浏览器，请扫码或手动输入网址") }:show()
            end
        end }
    end
    self:setDialog{ title = self.title, body = body, buttons = buttons }
end

return QR
