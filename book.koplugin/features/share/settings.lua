--[[--
书摘编辑页上次配置的读写。调用方改完 state 立刻 write，内部 flush 到 settings/share.lua。

@module koplugin.book.features.share.settings
--]]

local MoonSettings = require("utils.settings")
local Setting = require("features.share.setting")

local Settings = {}

local OWNER = "features.share"

--- 把当前编辑页选项立刻落到磁盘。
---@param state table|nil
function Settings.write(state)
    state = state or {}
    local font_id = state.font_id
    if type(font_id) ~= "string" or font_id == "" then font_id = nil end
    local font_name = font_id and state.font_name or nil
    if type(font_name) ~= "string" or font_name == "" then font_name = nil end
    local c = MoonSettings.get(OWNER)
    local theme, swatch = Setting.migrateTheme(state.theme, state.swatch)
    c.share_theme = theme
    c.share_font = font_id
    c.share_font_name = font_name
    c.share_swatch = swatch
    c.share_art = state.art
    -- 长卡片已下线，清掉旧值以免下次读到 true。
    c.share_long = false
    c.share_show_logo = state.show_logo ~= false
    MoonSettings.save(OWNER)
end

--- 读上次配置（未经 Editor.mergeState：非法主题或已删除的字体/插画由调用方回落）。
---@return table
function Settings.read()
    local c = MoonSettings.get(OWNER)
    local theme, swatch = Setting.migrateTheme(c.share_theme, c.share_swatch)
    return {
        theme = theme,
        font_id = c.share_font,
        font_name = c.share_font_name,
        swatch = swatch,
        art = c.share_art,
        show_logo = c.share_show_logo,
    }
end

return Settings
