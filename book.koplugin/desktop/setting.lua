--[[--
桌面的配置声明（settings/desktop.lua，经 `utils.settings.get("desktop")` 读写）。

@module koplugin.book.desktop.setting
--]]

return {
    defaults = {
        -- 首次安装已把 KOReader start_with 种成月读；之后尊重用户改动（menu.lua）。
        start_with_seeded = false,
        -- 启动项为月读时，顶部菜单的抽屉（文件浏览器）图标直接回月读桌面。
        drawer_opens_desktop = true,
        library_sort = "recent_added",
        library_view = "grid",
        home_topbar_items = {
            clock = true,
            source = true,
            memory = true,
            cache = true,
            storage = true,
            wifi = true,
            brightness = true,
            battery = true,
        },
    },
}
