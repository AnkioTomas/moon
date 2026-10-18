--[[--
界面壁纸设置入口。页内容由 features.wallpaper.page 画。

@module koplugin.book.features.wallpaper.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {
    wallpaper_source = "none",
    -- 总开关：关上就整个不画，下面两个作用面的开关原样留着。
    wallpaper_enabled = true,
    wallpaper_desktop = true,
    wallpaper_dialog = true,
    -- 顶栏 / 底栏要不要跟着透出壁纸；关的那条补回页面底色。
    wallpaper_topbar = true,
    wallpaper_tabbar = true,
    wallpaper_contain = false,
    wallpaper_opacity = 100,
}

--- 无默认值的持久键：用户选的自定义图 / 壁纸文件夹。
Setting.keys = { "wallpaper_custom_image", "wallpaper_folder" }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local Wallpaper = require("features.wallpaper.page")
    local on = require("features.wallpaper").anyEnabled()
    return {
        {
            id = "main",
            group = "desktop",
            order = 80,
            icon = "wallpaper",
            title = _("界面壁纸"),
            subtitle = _("桌面页、弹窗"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("界面壁纸"),
                preview = function(width) return Wallpaper.preview(width) end,
                sections = function()
                    return { { title = _("壁纸"), rows = Wallpaper:rows(desktop) } }
                end,
            },
        },
    }
end

return Setting
