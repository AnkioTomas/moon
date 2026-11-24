--[[--
界面显示的配置声明（settings/ui.lua，经 `utils.settings.get("ui")` 读写）：主题、缩放、字体、封面网格、遮罩、弹窗关闭手势、图书馆封面显示（library_*）。

@module koplugin.book.ui.setting
--]]

return {
    defaults = {
        ui_scale = 130,
        ui_font = "",
        ui_font_name = "",
        font_bold = false,
        -- 在线字体默认开启（旧版配置保留，避免旧设置文件出现未知键）。
        online_fonts = true,
        -- 字体存储迁移版本号：0 → 1 把旧 .moon/fonts 迁入 $DATA/fonts 用户字体目录。
        fonts_migrated_ver = 0,
        tabbar_labels = true,
        grid_max_cols = 4,
        mesh_mask = true,
        swipe_dismiss = "down",
        pager_keys = true,
        pager_swipe = true,
        pager_cycle = false,
        library_title = true,
        library_author = false,
        -- 混合模式下封面左上角显示书源名（仅混合模式生效）。
        library_source_tag = true,
        library_style = "kindle",
        -- 封面四角：theme 跟界面风格；round / square 只改封面，不动按钮和对话框。
        library_cover_radius = "theme",
        -- 封面来源：image 加载封面图（无图用文字封面）；text 一律不加载、只用文字封面。
        library_cover_mode = "image",
        -- 首页是否也用文字封面：默认 false（首页仍加载真实封面）；仅在 library_cover_mode=text 时生效。
        home_text_cover = false,
        -- 文字封面风格：color 按书名取色；plain 白底黑字。truncate：书名过长自动截断（否则缩小字号排满）。
        library_text_cover_style = "color",
        library_text_cover_truncate = true,
        library_tap = "open",
        -- 双击 / 长按封面：none / open / detail。开双击后书库页的单击要多等一个双击间隔。
        library_double_tap = "none",
        library_hold = "none",
        -- 封面 / 列表行的「更多」：detail 进详情、menu 弹详情页右上角菜单、none 不显示。
        library_more = "detail",
        library_random = true,
        -- 书库显示哪些分组页签（书籍恒显示）；文件夹只对本地源生效。
        library_tabs = { "books", "author", "series", "category", "folder" },
        -- 随机一本的范围：new = 只抽没开始读的，reading = 再包含阅读中的。
        random_scope = "new",
        -- 彩屏主题色补饱和：low / standard / high / max，见 Theme.SATURATION。
        color_saturation = "standard",
    },
    -- ui_theme 为 nil = 默认主题，见 ui.themes；theme_preset 为 nil = 默认色板（v0.2.46–48 写过的 theme_color 单色仍认，见 ui.themes.palettes）。
    keys = { "ui_theme", "theme_preset", "theme_color" },
}
