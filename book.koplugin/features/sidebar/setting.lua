--[[--
阅读页侧栏手势设置。

@module koplugin.book.features.sidebar.setting
--]]

local _ = require("gettext")

local GESTURES = {
    { value = "edge", text = _("左边缘右滑") },
    { value = "full", text = _("任意位置右滑") },
    { value = "off", text = _("关闭") },
}

---@param settings table
---@return string|nil
local function statusText(settings)
    local current = settings.sidebar_gesture
    for _idx, option in ipairs(GESTURES) do
        if option.value == current then return option.text end
    end
end

local Setting = {}

-- sidebar_gesture 取 GESTURES 的 value。
Setting.defaults = { sidebar_gesture = "edge" }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local MoonSettings = require("utils.settings")
    return {
        {
            id = "main",
            group = "reader",
            order = 120,
            icon = "swipe_right",
            title = _("侧栏手势"),
            subtitle = _("也可在 KOReader 手势管理中绑定「打开月读侧栏」"),
            status = statusText(MoonSettings.get("features.sidebar")),
            page = {
                title = _("侧栏手势"),
                sections = function()
                    local settings = MoonSettings.get("features.sidebar")
                    local current = settings.sidebar_gesture
                    return {
                        {
                            title = _("侧栏手势"),
                            rows = {
                                function(iw)
                                    return require("ui.themes.widgets.row").widget({
                                        width = iw,
                                        chevron = true,
                                        kind = "nav",
                                        icon = "swipe_right",
                                        title = _("侧栏手势"),
                                        subtitle = _("也可在 KOReader 手势管理中绑定「打开月读侧栏」"),
                                        status = statusText(settings),
                                        callback = function()
                                            require("ui.themes.widgets.list"):new{
                                                title = _("侧栏手势"),
                                                items = GESTURES,
                                                current = current,
                                                centered = true,
                                                on_select = function(value)
                                                    settings.sidebar_gesture = value
                                                    MoonSettings.save("features.sidebar", settings)
                                                    desktop:updateView()
                                                end,
                                            }:show()
                                        end,
                                    })
                                end,
                            },
                        },
                    }
                end,
            },
        },
    }
end

return Setting
