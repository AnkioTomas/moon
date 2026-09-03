--[[-- dictionary.init：开关开启时接管原生词典管理与查词切词典。 --]]

local Assert = require("support.assert")

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, text) return text end })
end

local settings = { dictionary_enabled = true }
package.preload["utils.settings"] = function()
    return { get = function() return settings end }
end
local reader_order = { search = { "dictionary_lookup", "wikipedia_lookup" } }
local filemanager_order = { search = { "dictionary_lookup", "wikipedia_lookup" } }
package.preload["ui/elements/reader_menu_order"] = function() return reader_order end
package.preload["ui/elements/filemanager_menu_order"] = function() return filemanager_order end

local manage_calls = 0
local download_calls = 0
local pick_opts
local manage_changed_callback
package.preload["ui.reader.dictionary"] = function()
    return {
        manage = function(_, changed_callback)
            manage_calls = manage_calls + 1
            manage_changed_callback = changed_callback
        end,
        download = function() download_calls = download_calls + 1 end,
        pick = function(_, opts) pick_opts = opts end,
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

local DictQuickLookup = {
    results = { { dict = "牛津", word = "test", definition = "x" } },
    dictionary = "牛津",
    word = "hello",
    is_wiki = false,
    displaydictname = "牛津",
    updated = 0,
    update = function(self) self.updated = self.updated + 1 end,
    onClose = function() end,
    onTap = function(...) return "native tap" end,
    changeDictionary = function(self, index, skip_update)
        if not self.results[index] then return end
        self.dictionary = self.results[index].dict
        self.displaydictname = self.dictionary
        if not skip_update then self:update() end
    end,
}
package.preload["ui/widget/dictquicklookup"] = function()
    return DictQuickLookup
end

package.loaded["dictionary.init"] = nil
local DictInit = require("dictionary.init")
Assert.is_true(DictInit.isEnabled())
DictInit.install()
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

DictQuickLookup:changeDictionary(1)
Assert.eq(DictQuickLookup.displaydictname, "牛津 ▼")
Assert.eq(DictQuickLookup.updated, 1)

local title = { dimen = {} }
DictQuickLookup.dict_title = title
Assert.is_true(DictQuickLookup:onTap(nil, {
    pos = { intersectWith = function(_, dimen) return dimen == title.dimen end },
}))
Assert.eq(pick_opts.word, "hello")
Assert.eq(pick_opts.current_name, "牛津")

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
Assert.eq(DictQuickLookup:onTap(nil, {
    pos = { intersectWith = function() return true end },
}), "native tap")
