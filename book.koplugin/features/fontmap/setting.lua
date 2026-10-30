--[[--
书籍自动发现的字体映射；按源字体族名记住选择，之后的书可复用。

@module koplugin.book.features.fontmap.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local Setting = {}

Setting.defaults = { enabled = false, mappings = {} }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return { {
        group = "reader", order = 18, id = "fontmap",
        row = function(iw)
            local Settings = require("utils.settings")
            local settings = Settings.get("features.fontmap")
            return require("ui.themes.widgets.row").widget({
                width = iw, chevron = false, kind = "toggle", icon = "font_download",
                title = _("书内字体映射"),
                subtitle = _("将书中指定的字体替换为本机字体"),
                status = settings.enabled and _("开") or _("关"), status_on = settings.enabled,
                callback = function()
                    settings.enabled = not settings.enabled
                    Settings.save("features.fontmap")
                    desktop:updateView()
                end,
            })
        end,
    } }
end

return Setting
