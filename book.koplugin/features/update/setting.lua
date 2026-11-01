--[[--
插件自更新配置键（settings/update.lua）与设置。
「自动检查更新」在维护组。手动检查挂在 setting.version_check：我的设备页的版本行点按 / 长按调用它。

@module koplugin.book.features.update.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {
    auto_update_check = false,
    update_last_checked_at = 0,
    resource_last_checked_at = 0,
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            group = "maintenance",
            order = 50,
            id = "update_auto",
            --- 只自动查询并提示，不自动安装。
            row = function(iw)
                local MoonSettings = require("utils.settings")
                local settings = MoonSettings.get("features.update")
                local enabled = settings.auto_update_check
                return require("ui.themes.widgets.row").widget({
                    width = iw, chevron = false,
                    kind = "toggle", icon = "update", title = _("自动检查更新"),
                    subtitle = _("每天最多检查一次，只提示不自动安装；含注音、输入法词库"),
                    status = enabled and _("开") or _("关"), status_on = enabled,
                    callback = function()
                        settings.auto_update_check = not enabled
                        MoonSettings.save("features.update", settings)
                        desktop:updateView()
                    end,
                })
            end,
        },
    }
end

require("utils.extension").add("setting.version_check", function(root, force)
    require("features.update").manualCheck(root, force)
end)

return Setting
