--[[--
锁屏壁纸设置入口。页内容仍由 features.lockscreen.page 画。

@module koplugin.book.features.lockscreen.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {
    lock_screen = "ko",
    lock_screen_background = "bing",
    lock_screen_component = "current",
    lock_screen_position = "center-center",
    lock_screen_wide = true,
    lock_screen_bill_period = "7d",
    lock_screen_poster_style = "vertical",
    lock_screen_custom_message = "读书不觉已春深，一寸光阴一寸金。",
}

--- 无默认值的持久键：当天生成标记、高亮轮换、用户选的自定义图 / 壁纸文件夹、背景主体拆分迁移标记。
Setting.keys = {
    "lock_screen_day", "lock_screen_quote_index", "lock_screen_custom_image", "lock_screen_folder",
    "lock_screen_split",
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local on = require("features.lockscreen.settings").isCompose()
    local Lockscreen = require("features.lockscreen.page")
    return {
        {
            id = "main",
            group = "desktop",
            order = 100,
            icon = "wallpaper",
            title = _("锁屏壁纸"),
            subtitle = _("替代系统锁屏"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("锁屏壁纸"),
                preview = function(width)
                    return Lockscreen.preview(width)
                end,
                sections = function()
                    return { { title = _("锁屏"), rows = Lockscreen:rows(desktop) } }
                end,
            },
        },
    }
end

return Setting
