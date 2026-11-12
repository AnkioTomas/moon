--[[--
书摘配置键（settings/share.lua）。编辑页上次的主题、字体、背景或插画、Logo。
改一项立刻 MoonSettings.save，下次打开接着用。本文件只声明键，不 require 界面模块。

@module koplugin.book.features.share.setting
--]]

local Setting = {}

Setting.defaults = {
    share_theme = "calendar",
    share_swatch = "default",
    share_show_logo = true,
}

-- 空值表示自动字体（优先宋体），或当前主题不用插画。
Setting.keys = { "share_font", "share_font_name", "share_art" }

--- 已下线的主题/选项：夜读并入纸页夜色，公众号长图改走纸页，长卡片废弃。
---@param theme string|nil
---@param swatch string|nil
---@return string|nil, string
function Setting.migrateTheme(theme, swatch)
    if type(swatch) ~= "string" or swatch == "" then swatch = "default" end
    if theme == "night" then
        if swatch == "default" then swatch = "night" end
        theme = "paper"
    elseif theme == "official" then
        theme = "paper"
    end
    return theme, swatch
end

return Setting
