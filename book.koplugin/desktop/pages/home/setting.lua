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
        -- 第一本 = 最近读的那本；列表默认留给「当前阅读」大卡片，堆叠卡片默认放中间。
        home_recent_list_show_first = false,
        home_recent_cards_show_first = true,
    },
    -- home_widgets 为 nil = 用默认布局，见 registry.lua。
    keys = { "home_widgets" },
}
