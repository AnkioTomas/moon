--[[--
拓展设置页：底栏「拓展」格开关（默认关）+ 逐项选择弹层里显示哪些插件入口。

`shown[<插件名>:<菜单键>]` 只记用户选过的项，没选过的按默认（第三方显示、自带隐藏），见 features.extensions。

@module koplugin.book.features.extensions.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = { enabled = false, shown = {} }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local MoonSettings = require("utils.settings")
    local settings = MoonSettings.get("features.extensions")
    return {
        {
            id = "main",
            group = "desktop",
            order = 70,
            icon = "extension",
            title = _("底栏拓展"),
            subtitle = _("在底栏列出其它插件的入口"),
            status = settings.enabled and _("开") or _("关"),
            status_on = settings.enabled,
            page = {
                title = _("底栏拓展"),
                sections = function()
                    local Extensions = require("features.extensions")
                    local Row = require("ui.themes.widgets.row")
                    local user, builtin = {}, {}
                    for _idx, entry in ipairs(Extensions.entries(desktop.plugin)) do
                        local rows = entry.builtin and builtin or user
                        rows[#rows + 1] = function(iw)
                            return Row.widget({
                                width = iw, title = entry.text,
                                toggle = Extensions.isShown(entry),
                                callback = function()
                                    Extensions.toggle(entry)
                                    desktop:updateView()
                                end,
                            })
                        end
                    end
                    if #user == 0 then
                        user[1] = function(iw)
                            return Row.widget({ width = iw, title = _("没有用户插件入口"), enabled = false })
                        end
                    end
                    local sections = {
                        { title = _("底栏"), rows = { function(iw)
                            return Row.widget({
                                width = iw, icon = "extension", title = _("在底栏显示拓展"),
                                toggle = settings.enabled,
                                callback = function()
                                    settings.enabled = not settings.enabled
                                    MoonSettings.save("features.extensions")
                                    desktop:updateView()
                                end,
                            })
                        end } },
                        { title = _("用户插件"), rows = user },
                    }
                    if #builtin > 0 then
                        sections[#sections + 1] = { title = _("KOReader 自带"), rows = builtin }
                    end
                    return sections
                end,
            },
        },
    }
end

return Setting
