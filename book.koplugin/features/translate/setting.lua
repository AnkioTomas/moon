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
            group = "reader",
            order = 14,
            icon = "translate",
            title = _("翻译"),
            subtitle = _("Edge 翻译与双语对照"),
            page = {
                title = _("翻译"),
                docs = "/manual/reader/smart/translate",
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
                    local colors = { [""] = _("跟随原文"), ["#333333"] = _("深灰"), ["#555555"] = _("灰"), ["#777777"] = _("浅灰") }
                    local function colorText(v) return colors[v or ""] or colors[""] end
                    local function scaleText(v)
                        v = v or 0
                        return v == 0 and _("跟随原文") or v .. "%"
                    end
                    local bilingual = {
                        function(iw)
                            return Row.widget({
                                width = iw, chevron = true,
                                kind = "nav", icon = "palette", title = _("双语对照"),
                                status = colorText(translate.bilingual_color) .. " · " .. scaleText(translate.bilingual_scale),
                                callback = function()
                                    local draft = {
                                        color = translate.bilingual_color or "",
                                        scale = translate.bilingual_scale or 0,
                                    }
                                    require("ui.themes.widgets.settings"):new{
                                        title = _("双语对照"),
                                        items = function()
                                            return {
                                                {
                                                    title = _("双语译文颜色"),
                                                    items = {
                                                        { value = "", text = colors[""] },
                                                        { value = "#333333", text = colors["#333333"] },
                                                        { value = "#555555", text = colors["#555555"] },
                                                        { value = "#777777", text = colors["#777777"] },
                                                    },
                                                    current = draft.color,
                                                    on_select = function(value) draft.color = value end,
                                                },
                                                {
                                                    title = _("双语译文字号"),
                                                    items = {
                                                        { value = 0, text = scaleText(0) },
                                                        { value = 80, text = "80%" },
                                                        { value = 90, text = "90%" },
                                                        { value = 100, text = "100%" },
                                                        { value = 110, text = "110%" },
                                                    },
                                                    current = draft.scale,
                                                    on_select = function(value) draft.scale = value end,
                                                },
                                            }
                                        end,
                                        buttons = function(page)
                                            return {
                                                { text = _("取消"), callback = function() page:close() end },
                                                { text = _("确定"), variant = "primary", callback = function()
                                                    translate.bilingual_color = draft.color
                                                    translate.bilingual_scale = draft.scale
                                                    MoonSettings.save("features.translate", translate)
                                                    page:close()
                                                    desktop:updateView()
                                                end },
                                            }
                                        end,
                                    }:show()
                                end,
                            })
                        end,
                    }
                    return { { title = _("翻译"), rows = rows }, { title = _("双语对照"), rows = bilingual } }
                end,
            },
        },
    }
end

return Setting
