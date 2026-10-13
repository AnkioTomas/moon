---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- reader.highlight_menu：划词按钮显隐门控、来源扫描与排序。 --]]

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
    reader_popup_seen = {},
}
local saves = 0
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        save = function(owner)
            Assert.eq(owner, "reader")
            saves = saves + 1
        end,
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

local HighlightMenu = require("reader.highlight_menu")
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

-- 来源：按工厂函数所在文件判断
local function defined_in(path)
    return load("return function() return { text = 'x' } end", "@" .. path)()
end
Assert.eq(HighlightMenu.originOf(defined_in("/mnt/us/koreader/plugins/qrclipboard.koplugin/main.lua")), "plugin:qrclipboard")
Assert.eq(HighlightMenu.originOf(defined_in("/mnt/us/koreader/plugins/book.koplugin/features/ai/explain.lua")), "book")
Assert.eq(HighlightMenu.originOf(defined_in("frontend/apps/reader/modules/readerhighlight.lua")), "koreader")
Assert.eq(HighlightMenu.originOf(defined_in("/mnt/us/koreader/patches/2-my-button.lua")), "patch:2-my-button")
Assert.eq(HighlightMenu.originOf(defined_in("somewhere.lua")), "unknown")

-- 未登记的按钮也受控：扫描记下来源，设置项 id 就是原键，可单独屏蔽
local saves_before = saves
factories["12_0_make_handmade_toc_item"] = defined_in("frontend/apps/reader/modules/readerhandmade.lua")
HighlightMenu.ensureWrapped(highlight)
Assert.eq(settings.reader_popup_seen["12_0_make_handmade_toc_item"].origin, "koreader")
Assert.eq(settings.reader_popup_seen.translate.origin, "unknown", "登记过的按钮按设置项 id 记")
Assert.is_true(saves > saves_before)
local toc_button = highlight._highlight_buttons["12_0_make_handmade_toc_item"]({}, nil)
Assert.is_true(toc_button.show_in_highlight_dialog_func())
settings.reader_popup_buttons["12_0_make_handmade_toc_item"] = false
Assert.is_false(toc_button.show_in_highlight_dialog_func())

-- 再扫一遍不重复包装、来源没变不落盘
saves_before = saves
local wrapped_toc = highlight._highlight_buttons["12_0_make_handmade_toc_item"]
HighlightMenu.ensureWrapped(highlight)
Assert.eq(highlight._highlight_buttons["12_0_make_handmade_toc_item"], wrapped_toc)
Assert.eq(saves, saves_before)

-- 原生移除后用同一个键重新注册：新工厂也要挂上门控
factories["12_0_make_handmade_toc_item"] = defined_in("frontend/apps/reader/modules/readerhandmade.lua")
HighlightMenu.ensureWrapped(highlight)
Assert.is_false(highlight._highlight_buttons["12_0_make_handmade_toc_item"]({}, nil).show_in_highlight_dialog_func())

-- 扫描到的按钮进排序：排在内置默认顺序之后
local order = HighlightMenu.order()
Assert.eq(order[#order], "12_0_make_handmade_toc_item")
