--[[--
Edge 翻译配置键（settings/translate.lua）与设置：往桌面「查词」页追加「翻译」分节。

@module koplugin.book.features.translate.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {
    edge_translation_enabled = true,
    bilingual_color = "",
    bilingual_scale = 0,
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
                local style = {}
                local function choice(key, title, icon, options, label)
                    return function(iw)
                        return Row.widget({
                            width = iw, chevron = true,
                            kind = "nav", icon = icon, title = title,
                            status = label(translate[key]),
                            callback = function()
                                local items = {}
                                for _idx, option in ipairs(options) do
                                    items[#items + 1] = { text = label(option), checked = option == translate[key], callback = function()
                                        translate[key] = option
                                        MoonSettings.save("features.translate", translate)
                                        desktop:updateView()
                                    end }
                                end
                                require("ui.themes.widgets.list"):new{ title = title, centered = true, items = items }:show()
                            end,
                        })
                    end
                end
                local colors = { [""] = _("跟随原文"), ["#333333"] = _("深灰"), ["#555555"] = _("灰"), ["#777777"] = _("浅灰") }
                style[#style + 1] = choice("bilingual_color", _("双语译文颜色"), "palette",
                    { "", "#333333", "#555555", "#777777" }, function(v) return colors[v] end)
                style[#style + 1] = choice("bilingual_scale", _("双语译文字号"), "format_size",
                    { 0, 80, 90, 100, 110 }, function(v) return v == 0 and _("跟随原文") or v .. "%" end)
                return { { title = _("翻译"), rows = rows }, { title = _("双语对照"), rows = style } }
            end,
        },
    }
end

return Setting
