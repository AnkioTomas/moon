--[[-- h\195\188zheng 目录解析及字典维护入口。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end

local Dictionary = require("ui.reader.dictionary")
local entries = Dictionary.parseDirectory([[
    <a href="zh_CN/">Chinese</a>
    <a href="stardict-ec-gb-2.4.2.tar.bz2">EC/GB</a>
    <a href="../private/">Private</a>
    <a href="https://example.test/bad.zip">Bad</a>
    <a href="note.txt">Ignore</a>
]], "http://download.huzheng.org/")

Assert.len(entries, 2)
Assert.is_true(entries[1].directory)
Assert.eq(entries[1].url, "http://download.huzheng.org/zh_CN/")
Assert.is_false(entries[2].directory)
Assert.eq(entries[2].url, "http://download.huzheng.org/stardict-ec-gb-2.4.2.tar.bz2")

local cleaned = Dictionary.parseDirectory([[<a href="stardict-oxford-v2.4.2.tar.bz2">stardict-oxford-v2.4.2.tar.bz2</a>]], "http://download.huzheng.org/en/")
Assert.eq(cleaned[1].name, "stardict-oxford-v2.4.2.tar.bz2")

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
Dictionary.open(ui)
Assert.eq(shown.title, "字典维护")
Assert.len(shown.buttons[1], 3)
Assert.eq(shown.buttons[1][1].icon, "cloud_download")
Assert.eq(shown.buttons[1][2].icon, "settings")
Assert.eq(shown.buttons[1][3].icon, "search")
shown.buttons[1][3].callback()
Assert.eq(lookup, 1)
