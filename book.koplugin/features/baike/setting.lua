--[[--
百度百科设置：往桌面「查词」页追加「百科」分节。

@module koplugin.book.features.baike.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = { baike_enabled = true }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            group = "reader",
            order = 17,
            icon = "public",
            title = _("百科"),
            subtitle = _("划词查百科"),
            page = {
                title = _("百科"),
                sections = function()
                    local MoonSettings = require("utils.settings")
                    local current = MoonSettings.get("features.baike")
                    local enabled = current.baike_enabled
                    return {
                        {
                            title = _("百科"),
                            rows = {
                                function(iw)
                                    return require("ui.themes.widgets.row").widget({
                                        width = iw,
                                        chevron = false,
                                        kind = "toggle",
                                        icon = "language",
                                        title = _("百度百科"),
                                        status = enabled and _("开") or _("关"),
                                        status_on = enabled,
                                        callback = function()
                                            current.baike_enabled = not enabled
                                            MoonSettings.save("features.baike", current)
                                            desktop:updateView()
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
