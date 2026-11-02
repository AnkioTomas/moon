--[[--
插件自更新配置键（settings/update.lua）。
手动检查挂在 setting.version_check：我的设备页的版本行点按 / 长按调用它。
自动检查没有开关：回到桌面前台时按间隔查询，只提示不安装。

@module koplugin.book.features.update.setting
--]]

local Setting = {}

Setting.defaults = {
    update_last_checked_at = 0,
    resource_last_checked_at = 0,
}

require("utils.extension").add("setting.version_check", function(root, force)
    require("features.update"):manualCheck(root, force)
end)

return Setting
