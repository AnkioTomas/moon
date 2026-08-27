--[[--
translate.languages 离线用例。
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end

G_reader_settings = {
    _data = {},
    saveSetting = function(self, key, value) self._data[key] = value end,
}

local Languages = require("translate.languages")
local translator = {
    getLanguageName = function(_, lang, fallback)
        if lang == "en" then return "English", true end
        if lang == "zh" then return "Chinese (Simplified)", true end
        return fallback or "?", false
    end,
}

local source_items = Languages.options(translator, true)
Assert.eq(source_items[1].value, "auto")
Assert.eq(source_items[1].text, "自动检测")
Assert.is_true(#source_items >= 3)

Assert.eq(Languages.displayName(translator, "auto", "en"), "English")
Assert.eq(Languages.displayName(translator, "auto", nil), "自动检测")
Assert.eq(Languages.displayName(translator, "zh", nil), "Chinese (Simplified)")

Languages.applySource("auto")
Assert.eq(G_reader_settings._data.translator_from_auto_detect, true)
Languages.applySource("en")
Assert.eq(G_reader_settings._data.translator_from_auto_detect, false)
Assert.eq(G_reader_settings._data.translator_from_language, "en")
Languages.applyTarget("zh")
Assert.eq(G_reader_settings._data.translator_to_language, "zh")
