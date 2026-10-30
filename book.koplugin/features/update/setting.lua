--[[--
插件自更新配置键（settings/update.lua）与设置：「自动检查更新」「检查更新」两行放在维护组「功能与更新」。

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
        {
            group = "maintenance",
            order = 60,
            id = "update_check",
            row = function(iw)
                local root = desktop.plugin.path
                return require("ui.themes.widgets.row").widget({
                    width = iw, chevron = false,
                    kind = "action", icon = "system_update", title = _("检查更新"),
                    subtitle = _("长按强制重装最新包"),
                    status = require("bookversion"), status_on = true,
                    callback = function()
                        require("features.update").manualCheck(root)
                    end,
                    hold_callback = function()
                        require("features.update").manualCheck(root, true)
                    end,
                })
            end,
        },
    }
end

return Setting
