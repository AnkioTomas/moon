--[[--
界面显示的配置声明（settings/ui.lua，经 `utils.settings.get("ui")` 读写）：主题、缩放、字体、封面网格、遮罩。

@module koplugin.book.ui.setting
--]]

return {
    defaults = {
        ui_scale = 130,
        ui_font = "",
        ui_font_name = "",
        grid_max_cols = 4,
        mesh_mask = true,
    },
    -- ui_theme 为 nil = 默认主题，见 ui.themes。
    keys = { "ui_theme" },
}
