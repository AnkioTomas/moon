--[[--
插件自更新配置键（settings/update.lua）。
手动检查挂在 setting.version_check：我的设备页的版本行点按 / 长按调用它。
自动检查没有开关：回到桌面前台时按间隔查询，只提示不安装。

@module koplugin.book.features.update.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {
    update_last_checked_at = 0,
    resource_last_checked_at = 0,
}

require("utils.extension").add("setting.version_check", function(root, force)
    require("features.update"):manualCheck(root, force)
end)

--- Kindle 书库依赖 kindle.koplugin：有 cc.db 的设备（Kindle）才给更新入口。
---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local Kindle = require("source.kindle")
    if require("libs/libkoreader-lfs").attributes(Kindle.CC_DB, "mode") ~= "file" then return {} end
    return { {
        group = "maintenance", order = 6, id = "kindle_plugin",
        row = function(iw)
            return require("ui.themes.widgets.row").widget({
                width = iw, kind = "nav", icon = "system_update", title = _("更新 kindle.koplugin"),
                subtitle = _("Kindle 书库依赖的插件，点按检查更新"),
                callback = function() require("source.kindle.plugin_update"):manualCheck(desktop.plugin) end,
            })
        end,
    } }
end

return Setting
