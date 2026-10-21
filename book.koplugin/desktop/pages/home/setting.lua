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
        -- 一言 / 书摘整个组件是否居中。
        home_hitokoto_center = false,
        home_excerpt_center = false,
        -- 书架：行数 1–4，0 = 自动按分配高度；每行 3–8 本。
        home_shelf_rows = 1,
        home_shelf_cols = 4,
    },
    -- home_widgets 为 nil = 用默认布局，见 registry.lua。
    keys = { "home_widgets" },
}
