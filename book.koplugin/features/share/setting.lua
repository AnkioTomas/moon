--[[--
书摘配置键（settings/share.lua）。编辑页上次的主题、字体、背景或插画、Logo。
改一项立刻 MoonSettings.save，下次打开接着用。声明键、迁移和共享归一化，不依赖界面模块。

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

Setting.SWATCH_HEX = {
    paper = 0xF6F1E8,
    white = 0xFFFFFF,
    night = 0x161513,
    ink = 0x2A2A28,
    slate = 0xD8DEDC,
    blush = 0xF3E4E1,
    blue = 0xE6EEF4,
}

--- 已下线的主题/选项：夜读并入纸页夜色，公众号长图改走纸页，长卡片废弃。
---@param theme string|nil
---@param swatch string|nil
---@return string|nil, string
function Setting.migrateTheme(theme, swatch)
    if type(swatch) ~= "string" or swatch == "" then swatch = "default" end
    if swatch ~= "default" and not Setting.SWATCH_HEX[swatch] then swatch = "default" end
    if theme == "night" then
        if swatch == "default" then swatch = "night" end
        theme = "paper"
    elseif theme == "official" then
        theme = "paper"
    end
    return theme, swatch
end

---@param state table|nil
---@return table
function Setting.normalize(state)
    state = state or {}
    local theme, swatch = Setting.migrateTheme(state.theme, state.swatch)
    local font = state.font
    if font ~= "song" and font ~= "hei" and font ~= "kai" and font ~= "fang" then font = "song" end
    local font_id = state.font_id
    if type(font_id) ~= "string" or font_id == "" then font_id = nil end
    local font_name = font_id and state.font_name or nil
    if type(font_name) ~= "string" or font_name == "" then font_name = nil end
    return {
        theme = theme,
        swatch = swatch,
        font = font,
        font_id = font_id,
        font_name = font_name,
        art = state.art,
        show_logo = state.show_logo ~= false,
    }
end

return Setting
