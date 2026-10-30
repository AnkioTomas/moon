--[[--
订阅设置：桌面「页面」分节里的三级页（启用订阅、下载文章图片）。
总开关默认关；关着时底栏不显示「订阅」、不做任何刷新。

@module koplugin.book.features.subscribe.setting
--]]

local _ = require("gettext")

local Setting = {}

-- images：打开文章时把图片下到本地（关掉省流量、省空间）。
Setting.defaults = { enabled = false, images = true }
-- filter：订阅页的筛选条件 { feed, grp, mode, q }。
Setting.keys = { "filter" }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local MoonSettings = require("utils.settings")
    local Row = require("ui.themes.widgets.row")
    local settings = MoonSettings.get("features.subscribe")
    local function toggleRow(key, icon, title, subtitle)
        return function(iw)
            return Row.widget({
                width = iw, icon = icon, title = title, subtitle = subtitle,
                toggle = settings[key],
                callback = function()
                    settings[key] = not settings[key]
                    MoonSettings.save("features.subscribe")
                    desktop:updateView()
                end,
            })
        end
    end
    return {
        {
            -- order 夹在图书馆(40) 与 书城(42) 之间，页面分节顺序：图书馆、订阅、书城、统计。
            id = "main", group = "desktop", order = 41,
            icon = "subscriptions", title = _("订阅"),
            subtitle = _("底栏订阅与文章图片"),
            page = {
                title = _("订阅"),
                sections = function()
                    return {{
                        title = _("订阅"),
                        rows = {
                            toggleRow("enabled", "subscriptions", _("启用订阅"),
                                _("在底栏「图书馆」旁显示「订阅」")),
                            toggleRow("images", "image", _("下载文章图片")),
                        },
                    }}
                end,
            },
        },
    }
end

return Setting
