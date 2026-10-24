--[[--
界面壁纸设置入口。页内容由 features.wallpaper.page 画。

@module koplugin.book.features.wallpaper.setting
--]]

local _ = require("gettext")

local Setting = {}

--- 作用面 id：桌面各页签、设置叠层、其余弹窗、阅读页。
Setting.SCOPES = { "home", "library", "store", "insight", "settings", "dialog", "reader" }

Setting.defaults = {
    -- 总开关：关上就整个不画，各界面的开关原样留着。
    wallpaper_enabled = true,
    -- 旧版的两个作用面开关：没单独存过的界面沿用它们。默认关：选了图也不该铺满所有界面，由用户逐个打开。
    wallpaper_desktop = false,
    wallpaper_dialog = false,
    -- 顶栏 / 底栏要不要跟着透出壁纸；关的那条补回页面底色。
    wallpaper_topbar = true,
    wallpaper_tabbar = true,
    -- 底栏透出壁纸时：选中格不填深色块、图标文字跟正文同色。默认关（保持原来的强调样式）。
    wallpaper_tabbar_plain = false,
    wallpaper_contain = false,
    -- 默认淡一点：选了图铺满各界面时不至于盖住内容。
    wallpaper_opacity = 30,
}

--- 无默认值的持久键：全局图，以及各界面的开关与图 / 铺法 / 透明度覆盖（没设 = 跟随全局）。
Setting.keys = { "wallpaper_custom_image" }
for _idx, scope in ipairs(Setting.SCOPES) do
    for _field_idx, prefix in ipairs({ "wallpaper_", "wallpaper_image_", "wallpaper_contain_", "wallpaper_opacity_" }) do
        Setting.keys[#Setting.keys + 1] = prefix .. scope
    end
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local Wallpaper = require("features.wallpaper.page")
    local on = require("features.wallpaper").anyEnabled()
    return {
        {
            id = "main",
            group = "appearance",
            order = 20,
            icon = "wallpaper",
            title = _("界面壁纸"),
            subtitle = _("全局设置，各界面可单独调整"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = Wallpaper.spec(desktop),
        },
    }
end

return Setting
