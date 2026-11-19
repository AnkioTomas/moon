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
    lock_screen_poster_sort = "recent_read",
    lock_screen_poster_source = "",
    lock_screen_insight_page = "random",
    lock_screen_custom_message = "读书不觉已春深，一寸光阴一寸金。",
}

--- 无默认值的持久键：当天生成标记、高亮轮换、用户选的自定义图 / 壁纸文件夹、背景主体拆分迁移标记、文字海报版式与字体。
Setting.keys = {
    "lock_screen_day", "lock_screen_transparent", "lock_screen_quote_index", "lock_screen_custom_image", "lock_screen_folder",
    "lock_screen_split", "lock_screen_typo_style", "lock_screen_typo_font", "lock_screen_typo_font_name",
}

-- 无操作多久自动休眠（秒）；-1 = 从不。
local function suspendDelays()
    return {
        { value = 60, text = _("1 分钟") },
        { value = 120, text = _("2 分钟") },
        { value = 300, text = _("5 分钟") },
        { value = 600, text = _("10 分钟") },
        { value = 900, text = _("15 分钟") },
        { value = 1800, text = _("30 分钟") },
        { value = 3600, text = _("1 小时") },
        { value = -1, text = _("从不") },
    }
end

---@param desktop BookDesktop
---@return fun(iw: number): table
local function suspendRow(desktop)
    return function(iw)
        local Settings = require("features.lockscreen.settings")
        local items, current = suspendDelays(), Settings.autoSuspend()
        local status
        for _idx, item in ipairs(items) do
            if item.value == current then status = item.text end
        end
        -- 在 KOReader 里自定义过、不在预设里的值显示成分钟数。
        status = status or require("ffi/util").template(_("%1 分钟"), math.ceil(current / 60))
        return require("ui.themes.widgets.row").choice({
            width = iw, icon = "timer", title = _("自动锁屏时间"),
            subtitle = _("无操作超过这段时间后自动休眠并锁屏"),
            items = items, current = current, status = status, status_on = current > 0,
            on_select = function(value)
                Settings.setAutoSuspend(value, desktop.plugin and desktop.plugin.ui)
                desktop:updateView()
            end,
        })
    end
end

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local on = require("features.lockscreen.settings").isCompose()
    local Lockscreen = require("features.lockscreen.page")
    return {
        {
            id = "main",
            group = "security",
            order = 10,
            icon = "wallpaper",
            title = _("锁屏壁纸"),
            subtitle = _("替代系统锁屏"),
            status = on and _("开") or _("关"),
            status_on = on,
            page = {
                title = _("锁屏壁纸"),
                docs = "/manual/security/lockscreen",
                preview = function(width)
                    return Lockscreen.preview(width)
                end,
                sections = function()
                    return { { title = _("锁屏"), rows = Lockscreen:rows(desktop) } }
                end,
            },
        },
        { id = "auto_lock", group = "security", order = 30, row = suspendRow(desktop) },
    }
end

return Setting
