--[[--
界面显示的配置声明（settings/ui.lua，经 `utils.settings.get("ui")` 读写）：主题、缩放、字体、封面网格、遮罩、弹窗关闭手势、图书馆封面显示（library_*）。

@module koplugin.book.ui.setting
--]]

return {
    defaults = {
        ui_scale = 130,
        ui_font = "",
        ui_font_name = "",
        grid_max_cols = 4,
        mesh_mask = true,
        swipe_dismiss = "down",
        library_title = true,
        library_author = false,
        library_style = "kindle",
        library_tap = "open",
        library_random = true,
        -- 书库显示哪些分组页签（书籍恒显示）；文件夹只对本地源生效。
        library_tabs = { "books", "author", "series", "category", "folder" },
        -- 随机一本的范围：new = 只抽没开始读的，reading = 再包含阅读中的。
        random_scope = "new",
    },
    -- ui_theme 为 nil = 默认主题，见 ui.themes。
    keys = { "ui_theme" },
}
