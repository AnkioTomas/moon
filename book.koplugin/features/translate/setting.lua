--[[--
Edge 翻译配置键（settings/translate.lua）与设置：往桌面「划词与查询」页追加「翻译」分节。

@module koplugin.book.features.translate.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {
    edge_translation_enabled = true,
    translate_languages = { "en", "zh", "ja", "fr", "de", "ko", "es", "ru", "zh_TW" },
}

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            parent = "lookup",
            order = 30,
            sections = function()
                local MoonSettings = require("utils.settings")
                local Row = require("ui.themes.widgets.row")
                local translate = MoonSettings.get("features.translate")
                local on = translate.edge_translation_enabled
                local rows = {
                    function(iw)
                        return Row.widget({
                            width = iw, chevron = false,
                            kind = "toggle", icon = "translate", title = _("Edge 翻译"),
                            status = on and _("开") or _("关"), status_on = on,
                            callback = function()
                                translate.edge_translation_enabled = not on
                                MoonSettings.save("features.translate", translate)
                                desktop:updateView()
                            end,
                        })
                    end,
                }
                if on then
                    rows[#rows + 1] = function(iw)
                        local Languages = require("features.translate.languages")
                        return Row.widget({
                            width = iw, chevron = true,
                            kind = "nav", icon = "translate", title = _("常用翻译语言"),
                            status = require("ffi/util").template(_("%1 种"), #Languages.favoriteCodes()),
                            callback = function()
                                Languages.openSettingsPicker(require("ui/translator"), desktop)
                            end,
                        })
                    end
                end
                return { { title = _("翻译"), rows = rows } }
            end,
        },
    }
end

return Setting
