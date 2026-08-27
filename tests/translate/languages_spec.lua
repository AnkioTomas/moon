--[[--
translate.languages 离线用例。
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/components/popup"] = function()
    return { multi = function() end }
end

G_reader_settings = {
    _data = {},
    saveSetting = function(self, key, value) self._data[key] = value end,
}

package.preload["utils.settings"] = function()
    local data = {
        reader = {
            translate_languages = { "en", "zh", "ja" },
        },
    }
    return {
        get = function(section)
            if section then return data[section] end
            local out = {}
            for _, t in pairs(data) do
                for k, v in pairs(t) do out[k] = v end
            end
            return out
        end,
        saveSection = function(section, value)
            data[section] = value
        end,
    }
end

local Languages = require("translate.languages")
local translator = {
    getLanguageName = function(_, lang, fallback)
        if lang == "en" then return "English", true end
        if lang == "zh" then return "Chinese (Simplified)", true end
        return fallback or "?", false
    end,
}

Assert.eq(#Languages.favoriteCodes(), 3)

local picker = Languages.pickerItems(translator, true, "fr")
Assert.eq(picker[1].value, "auto")
Assert.eq(picker[#picker].value, Languages.ALL_LANGUAGES)
Assert.eq(picker[#picker].text, "全部语言…")

local seen_fr = false
for _, item in ipairs(picker) do
    if item.value == "fr" then seen_fr = true end
end
Assert.is_true(seen_fr, "current language appended when not in favorites")

Assert.eq(Languages.displayName(translator, "auto", "en"), "English")
Assert.eq(Languages.displayName(translator, "auto", "zh-Hans"), "Chinese (Simplified)")
Assert.eq(Languages.displayName(translator, "auto", nil), "自动检测")
Assert.eq(Languages.displayName(translator, "zh", nil), "Chinese (Simplified)")

Languages.applySource("auto")
Assert.eq(G_reader_settings._data.translator_from_auto_detect, true)
Languages.applySource("en")
Assert.eq(G_reader_settings._data.translator_from_auto_detect, false)
Assert.eq(G_reader_settings._data.translator_from_language, "en")
Languages.applyTarget("zh")
Assert.eq(G_reader_settings._data.translator_to_language, "zh")

Languages.saveFavorites({ "de", "fr" })
Assert.eq(#Languages.favoriteCodes(), 2)
