--[[--
书城总开关、来源开关与上次选的搜索来源的配置声明（settings/store.lua，经 `utils.settings.get("store")` 读写）。
各书城自己的账号 / 目录配置仍在 getSource("zlib" | "opds")。

@module koplugin.book.store.setting
--]]

return {
    defaults = {
        enabled = true,
        zlib_enabled = false,
        opds_enabled = false,
        provider = "",
    },
}
