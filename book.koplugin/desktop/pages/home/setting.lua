--[[--
首页的配置声明（settings/home.lua，经 `utils.settings.get("desktop.pages.home")` 读写）。

@module koplugin.book.desktop.pages.home.setting
--]]

return {
    defaults = {
        home_weather_city = "",
        home_clock_weather_order = "weather_left",
        home_recent_list_rows = 2,
        home_recent_list_cols = 4,
        home_recent_list_show_title = true,
    },
    -- home_widgets 为 nil = 用默认布局，见 registry.lua。
    keys = { "home_widgets" },
}
