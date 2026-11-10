--[[--
utils 的配置声明（settings/utils.lua，经 `utils.settings.get("utils")` 读写）：设备名称与设备头像（utils.device）。

@module koplugin.book.utils.setting
--]]

return {
    defaults = { device_name = "", device_logo = "" },
}
