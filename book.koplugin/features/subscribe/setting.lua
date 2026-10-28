--[[--
订阅设置：直接放在设置根页「订阅」组里的两个开关（不另开子页）。
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
    local settings = MoonSettings.get("features.subscribe")
    local function toggle(order, key, icon, title, subtitle)
        return {
            group = "subscribe",
            order = order,
            row = function(iw)
                return require("ui.themes.widgets.row").widget({
                    width = iw, icon = icon, title = title, subtitle = subtitle,
                    toggle = settings[key],
                    callback = function()
                        settings[key] = not settings[key]
                        MoonSettings.save("features.subscribe")
                        desktop:updateView()
                    end,
                })
            end,
        }
    end
    return {
        toggle(10, "enabled", "subscriptions", _("启用订阅"), _("在底栏「图书馆」旁显示「订阅」")),
        toggle(20, "images", "image", _("下载文章图片")),
    }
end

return Setting
