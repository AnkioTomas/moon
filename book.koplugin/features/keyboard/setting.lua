--[[--
键盘收起键设置：往「输入法」页追加一个开关（默认开），下次弹出键盘生效。

@module koplugin.book.features.keyboard.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = { enabled = true }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            parent = "feature:ime:main",
            order = 20,
            sections = function()
                local MoonSettings = require("utils.settings")
                local Row = require("ui.themes.widgets.row")
                local settings = MoonSettings.get("features.keyboard")
                return { { title = _("虚拟键盘"), rows = { function(iw)
                    return Row.widget({
                        width = iw,
                        chevron = false,
                        kind = "toggle",
                        icon = "keyboard",
                        title = _("键盘收起键"),
                        status = settings.enabled and _("开") or _("关"),
                        status_on = settings.enabled,
                        callback = function()
                            settings.enabled = not settings.enabled
                            MoonSettings.save("features.keyboard")
                            desktop:updateView()
                        end,
                    })
                end } } }
            end,
        },
    }
end

return Setting
