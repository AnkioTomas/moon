--[[--
网页二维码在非墨水屏设备提供本机浏览器入口，打开不能销毁验证会话。

@module tests.ui.themes.widgets.qr_spec
--]]
---@diagnostic disable: inject-field
local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local QR = require("ui.themes.widgets.qr")
local Device = require("device")
local opened
Device.hasEinkScreen = function() return false end
Device.canOpenLink = function() return true end
Device.openLink = function(_self, url) opened = url; return true end
local closed = false
local qr = QR:new{ text = "http://192.0.2.1/changpei_verify.html#ticket", close_callback = function() closed = true end }
local buttons = Kit.buttons(qr)
Assert.eq(buttons[1].text, "在本机打开")
buttons[1]:onTapThemeButton()
Assert.eq(opened, qr.text)
Assert.is_false(closed, "浏览器验证期间二维码会话必须保留")
Device.hasEinkScreen = function() return true end
Assert.len(Kit.buttons(QR:new{ text = qr.text }), 0)
Device.isSDL = function() return true end
Assert.eq(Kit.buttons(QR:new{ text = qr.text })[1].text, "在本机打开", "桌面模拟器即使模拟墨水屏也能开浏览器")
Device.isSDL = function() return false end
Device.hasEinkScreen = function() return false end
Device.canOpenLink = function() return false end
Assert.len(Kit.buttons(QR:new{ text = qr.text }), 0)
Device.canOpenLink = function() return true end
Assert.len(Kit.buttons(QR:new{ text = "not-a-link" }), 0)
Device.openLink = function() return false end
local failure = QR:new{ text = qr.text }
Kit.buttons(failure)[1]:onTapThemeButton()
Assert.eq(Kit.shown[#Kit.shown].text, "无法打开浏览器，请扫码或手动输入网址")

local refreshed = false
local image = QR:new{
    image = {}, close_on_tap = false,
    actions = { { text = "刷新", callback = function() refreshed = true end } },
}
Assert.len(Kit.buttons(image), 1, "官方二维码图片不生成网址或本机浏览器按钮")
Kit.buttons(image)[1]:onTapThemeButton()
Assert.is_true(refreshed)
