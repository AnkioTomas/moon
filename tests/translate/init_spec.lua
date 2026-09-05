--[[--
翻译注入：替换 Translator.showTranslation。
@module tests.translate.init_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
local popup_opts
package.preload["translate.popup"] = function()
    return { open = function(opts) popup_opts = opts end }
end
package.preload["translate.edge"] = function()
    return {
        translateAsync = function() error("not called by install") end,
    }
end
local reader = { edge_translation_enabled = true }
package.preload["utils.settings"] = function()
    return { get = function() return reader end }
end
package.preload["device"] = function()
    return { hasClipboard = function() return false end }
end
package.preload["ui/network/manager"] = function()
    return { willRerunWhenOnline = function() return false end }
end

local native_calls = 0
local translator = {
    showTranslation = function()
        native_calls = native_calls + 1
        return "native"
    end,
}
package.preload["ui/translator"] = function() return translator end

local native = translator.showTranslation
local Translate = require("translate.init")
Translate.install()
Assert.is_false(translator.showTranslation == native, "install 必须替换掉原生实现")

local before = translator.showTranslation
Translate.install()
Assert.eq(translator.showTranslation, before)

reader.edge_translation_enabled = false
Assert.eq(translator:showTranslation("text"), "native")
Assert.eq(native_calls, 1)

reader.edge_translation_enabled = true
translator.getSourceLanguage = function() return "zh" end
translator.getTargetLanguage = function() return "en" end
translator:showTranslation("整页文本", false)
Assert.is_true(popup_opts.full_page)
Assert.eq(popup_opts.text, "整页文本")
