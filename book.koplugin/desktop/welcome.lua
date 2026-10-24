--[[--
首次使用引导：全新安装后桌面第一次回到前台时问一次要不要看文档。

标记由首装种子（menu.lua）置真，这里先清标记再弹窗：无论选哪个都只问一次。

@module koplugin.book.desktop.welcome
--]]

require("l10n").apply()

local Device = require("device")
local Settings = require("utils.settings")
local Confirm = require("ui.themes.widgets.confirm")
local QR = require("ui.themes.widgets.qr")
local _ = require("gettext")

local DOCS_URL = "https://moon.ankio.net"

local Welcome = {}

function Welcome.promptDocs()
    local desktop = Settings.get("desktop")
    if not desktop.docs_prompt_pending then return end
    desktop.docs_prompt_pending = false
    Settings.save("desktop")
    Confirm:new{
        title = _("欢迎使用月读"),
        text = _("要看看使用文档吗？\n之后也可以在「设置 → 维护 → 关于」里找到项目主页。"),
        ok_text = _("查看文档"),
        cancel_text = _("以后再说"),
        ok_callback = function()
            if Device:canOpenLink() then
                Device:openLink(DOCS_URL)
            else
                QR:new{ title = _("使用文档"), text = DOCS_URL, caption = DOCS_URL }:show()
            end
        end,
    }:show()
end

return Welcome
