--[[-- features.dictionary.init：开关开启时接管原生词典管理与查词切词典。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, text) return text end })
end

local settings = { dictionary_enabled = true }
package.preload["utils.settings"] = function()
    return { get = function(name) assert(name == "features.dictionary"); return settings end }
end
local reader_order = { search = { "dictionary_lookup", "wikipedia_lookup" } }
local filemanager_order = { search = { "dictionary_lookup", "wikipedia_lookup" } }
package.preload["ui/elements/reader_menu_order"] = function() return reader_order end
package.preload["ui/elements/filemanager_menu_order"] = function() return filemanager_order end

local manage_calls = 0
local download_calls = 0
local manage_changed_callback
package.preload["features.dictionary.ui"] = function()
    return {
        manage = function(_, changed_callback)
            manage_calls = manage_calls + 1
            manage_changed_callback = changed_callback
        end,
        download = function() download_calls = download_calls + 1 end,
    }
end

local native_show_calls = 0
local native_download_calls = 0
local ReaderDictionary = {
    showDictionariesMenu = function(...)
        native_show_calls = native_show_calls + 1
        return "native manage"
    end,
    _genDownloadDictionariesMenu = function(...)
        native_download_calls = native_download_calls + 1
        return { { text = "native download" } }
    end,
    addToMainMenu = function(self, menu_items)
        menu_items.dictionary_settings = {
            sub_item_table = {
                { text = "presets", sub_item_table_func = function() return {} end },
                {
                    text = "download",
                    separator = true,
                    sub_item_table_func = function()
                        return self:_genDownloadDictionariesMenu()
                    end,
                },
            },
        }
    end,
}
package.preload["apps/reader/modules/readerdictionary"] = function()
    return ReaderDictionary
end

local shown
package.preload["features.rare.lookup"] = function()
    return { open = function(opts) shown = opts end }
end
ReaderDictionary.onLookupWord = function(...) return "native lookup" end

package.loaded["features.dictionary"] = nil
local DictInit = require("features.dictionary")
Assert.is_true(DictInit.isEnabled())
DictInit.onCreate()
Assert.is_true(ReaderDictionary._book_dict_installed)
Assert.eq(reader_order.search[2], "dictionary_download")
Assert.eq(filemanager_order.search[2], "dictionary_download")

local changed_calls = 0
Assert.eq(ReaderDictionary.showDictionariesMenu({ ui = {} }, function()
    changed_calls = changed_calls + 1
end), nil)
Assert.eq(manage_calls, 1)
Assert.eq(native_show_calls, 0)
Assert.eq(changed_calls, 0)
manage_changed_callback()
Assert.eq(changed_calls, 1)

local menu_items = {}
ReaderDictionary.addToMainMenu(ReaderDictionary, menu_items)
local download_item = menu_items.dictionary_download
Assert.len(menu_items.dictionary_settings.sub_item_table, 1)
Assert.is_nil(download_item.sub_item_table_func)
download_item.callback()
Assert.eq(download_calls, 1)
Assert.eq(native_download_calls, 0)

-- 查词改开多来源面板；维基（ui.dictionary 不是自己）走原生
local reader_ui = {}
local dict = setmetatable({ ui = reader_ui, cleanSelection = function(_, w) return w .. "!" end }, { __index = ReaderDictionary })
reader_ui.dictionary = dict
Assert.is_true(dict:onLookupWord("moon", false, nil, {}))
Assert.eq(shown.text, "moon!")
Assert.eq(shown.ui, reader_ui)
Assert.is_true(shown.from_highlight)
local wiki = setmetatable({ ui = reader_ui }, { __index = ReaderDictionary })
Assert.eq(wiki:onLookupWord("moon"), "native lookup")

settings.dictionary_enabled = false
Assert.is_false(DictInit.isEnabled())
local native_menu_items = {}
ReaderDictionary.addToMainMenu(ReaderDictionary, native_menu_items)
Assert.is_nil(native_menu_items.dictionary_download)
Assert.len(native_menu_items.dictionary_settings.sub_item_table, 2)
Assert.is_true(type(native_menu_items.dictionary_settings.sub_item_table[2].sub_item_table_func) == "function")
native_menu_items.dictionary_settings.sub_item_table[2].sub_item_table_func()
Assert.eq(native_download_calls, 1)
Assert.eq(ReaderDictionary.showDictionariesMenu({ ui = {} }), "native manage")
Assert.eq(native_show_calls, 1)
Assert.eq(dict:onLookupWord("moon"), "native lookup", "关闭后查词回退原生")
