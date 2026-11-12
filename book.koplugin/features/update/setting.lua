--[[--
插件自更新配置键（settings/update.lua）。
手动检查挂在 setting.version_check：我的设备页的版本行点按 / 长按调用它。
自动检查默认开启，可在我的设备页关闭，只提示不安装。

@module koplugin.book.features.update.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {
    auto_check = true,
    update_last_checked_at = 0,
    resource_last_checked_at = 0,
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            parent = "my_device",
            order = 10,
            sections = function()
                return {{
                    title = _("更新"),
                    rows = {
                        function(iw)
                            local Settings = require("utils.settings")
                            local settings = Settings.get("features.update")
                            local on = settings.auto_check
                            return require("ui.themes.widgets.row").widget({
                                width = iw, kind = "toggle", chevron = false,
                                icon = "system_update", title = _("自动检查更新"),
                                status = on and _("开") or _("关"), status_on = on,
                                callback = function()
                                    settings.auto_check = not on
                                    Settings.save("features.update")
                                    desktop:updateView()
                                end,
                            })
                        end,
                    },
                }}
            end,
        },
    }
end

require("utils.extension").add("setting.version_check", function(root, force)
    require("features.update"):manualCheck(root, force)
end)

return Setting
