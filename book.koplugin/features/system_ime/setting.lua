--[[--
系统输入法（Android 后端）的配置声明。

本 feature 不提供设置入口（入口已并入 features.ime）；这里只声明键，
让 `utils.settings` 能读到旧 `system_ime.lua` 并完成迁移。

@module koplugin.book.features.system_ime.setting
--]]

local Setting = {}

-- enabled 只用于迁移到 features.ime.input_mode；新代码不再读它。
Setting.defaults = {
    enabled = true,
}

-- last_status / test_result 由后端与设置页展示使用，无默认值。
Setting.keys = { "last_status", "test_result" }

return Setting
