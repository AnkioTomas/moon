--[[--
翻译注入：替换 Translator.showTranslation。
@module tests.translate.init_spec
--]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["translate.popup"] = function()
    return { open = function() end }
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
