--[[-- ui.reader.highlight_menu：原生划词按钮显隐门控。 --]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()
Stubs.reset()

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["ui/widget/buttondialog"] = function() return {} end

local settings = {
    reader_popup_buttons = { dictionary = false, qrcode = false },
    reader_popup_button_order = { "translate", "dictionary" },
}
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
    }
end

local factories = {
    ["06_dictionary"] = function()
        return { text = "Dictionary" }
    end,
    ["12_generate_qr_code"] = function()
        return { text = "Generate QR code" }
    end,
}

local highlight = { _highlight_buttons = factories }
local ui = { highlight = highlight }

local HighlightMenu = require("ui.reader.highlight_menu")
HighlightMenu.ensureWrapped(highlight)

local dict = highlight._highlight_buttons["06_dictionary"]({}, nil)
Assert.is_false(dict.show_in_highlight_dialog_func())

local qr = highlight._highlight_buttons["12_generate_qr_code"]({}, nil)
Assert.is_false(qr.show_in_highlight_dialog_func())

settings.reader_popup_buttons.dictionary = true
Assert.is_true(dict.show_in_highlight_dialog_func())

HighlightMenu.ensureWrapped(highlight)
local dict2 = highlight._highlight_buttons["06_dictionary"]({}, nil)
Assert.is_true(dict2.show_in_highlight_dialog_func())

factories["07_translate"] = function() return { text = "Translate" } end
HighlightMenu.ensureWrapped(highlight)
local ordered = HighlightMenu.orderedFactories(highlight)
Assert.eq(ordered[1].index, "07_translate")
Assert.eq(ordered[2].index, "06_dictionary")
