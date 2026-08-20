--[[-- 阅读页字典维护入口。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end

local shown
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, opts) return opts end }
end
package.preload["ui/uimanager"] = function()
    return { show = function(_, widget) shown = widget end, close = function() end }
end
package.loaded["ui/uimanager"] = nil

local lookup = 0
local ui = {
    dictionary = {
        onShowDictionaryLookup = function() lookup = lookup + 1 end,
        showDictionariesMenu = function() error("must not use native dictionary manager") end,
    },
}
local Dictionary = require("ui.reader.dictionary")
Dictionary.open(ui)
Assert.eq(shown.title, "字典维护")
Assert.len(shown.buttons[1], 3)
Assert.eq(shown.buttons[1][1].icon, "cloud_download")
Assert.eq(shown.buttons[1][2].icon, "settings")
Assert.eq(shown.buttons[1][3].icon, "search")
shown.buttons[1][3].callback()
Assert.eq(lookup, 1)
