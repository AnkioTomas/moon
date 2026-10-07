--[[--
utils 的配置声明（settings/utils.lua，经 `utils.settings.get("utils")` 读写）：调试日志开关（utils.log）。

@module koplugin.book.utils.setting
--]]

return {
    defaults = { book_debug_enabled = false },
}
