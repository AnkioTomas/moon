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

local translator = {
    showTranslation = function() end,
}
package.preload["ui/translator"] = function() return translator end

local native = translator.showTranslation
local Translate = require("translate.init")
Translate.install()
Assert.is_false(translator.showTranslation == native, "install 必须替换掉原生实现")

local before = translator.showTranslation
Translate.install()
Assert.eq(translator.showTranslation, before)
