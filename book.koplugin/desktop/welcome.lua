--[[--
首次使用引导：全新安装后桌面第一次回到前台时打开账号页，并问一次要不要看文档。

标记由首装种子（menu.lua）置真，这里先清标记再动作：无论选哪个都只问一次。

@module koplugin.book.desktop.welcome
--]]

require("l10n").apply()

local Device = require("device")
local Settings = require("utils.settings")
local Confirm = require("ui.themes.widgets.confirm")
local Docs = require("utils.docs")
local QR = require("ui.themes.widgets.qr")
local _ = require("gettext")

local GROUP_URL = "https://qm.qq.com/q/yLPC4fxb1K"

local Welcome = {}

--- 能直接开链接就开；墨水屏等开不了的设备出二维码，扫码打开同一地址。
---@param url string
---@param title string 二维码弹窗标题
local function open(url, title)
    if Device:canOpenLink() then
        Device:openLink(url)
    else
        QR:new{ title = title, text = url, caption = url }:show()
    end
end

--- 首次使用：打开账号页，再问要不要看文档。desk 是桌面实例；老代码无参时只弹文档。
---@param desk BookDesktop|nil
function Welcome.promptDocs(desk)
    local desktop = Settings.get("desktop")
    if not desktop.docs_prompt_pending then return end
    desktop.docs_prompt_pending = false
    Settings.save("desktop")
    if desk then
        require("desktop.pages.setting.source").openAccount(desk)
    end
    Confirm:new{
        title = _("欢迎使用月读"),
        text = _("先在账号页登录要用的书源。要看看使用指南吗？\n之后也可以在「设置 → 设备 → 我的设备」页底的「查看指南」打开。"),
        ok_text = _("查看指南"),
        cancel_text = _("以后再说"),
        extra_text = _("加入交流群"),
        ok_callback = function() Docs.open("/manual", _("使用指南")) end,
        extra_callback = function() open(GROUP_URL, _("加入交流群")) end,
    }:show()
end

return Welcome
