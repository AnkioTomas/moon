--[[--
锁屏密码配置（settings/passcode.lua：salt / hash / fails / locked_until，全部无默认值）与设置入口。

@module koplugin.book.features.passcode.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local on = require("utils.settings").get("features.passcode").hash ~= nil
    return {
        {
            id = "main",
            group = "desktop",
            order = 100,
            icon = "lock",
            title = _("锁屏密码"),
            subtitle = _("开机和唤醒时需要输入数字密码"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("锁屏密码"),
                sections = function()
                    return { { title = _("密码"), rows = require("features.passcode.page").rows(desktop) } }
                end,
            },
        },
    }
end

return Setting
