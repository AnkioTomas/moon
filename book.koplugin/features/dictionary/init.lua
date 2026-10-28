--[[--
把 KOReader 原生词典管理换成 Book 词典下载/切换。

保留查词事件与划词按钮；开启时接管「管理词典 / 下载词典」菜单，
查词结果改在多来源查词面板（features.rare.lookup）里按词典分栏显示。关闭后完整回退原生。

@module koplugin.book.features.dictionary.init
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")

local DictInit = {}
local DOWNLOAD_ITEM_ID = "dictionary_download"

--- 把下载入口排在查词之后；菜单项本身由 ReaderDictionary.addToMainMenu 提供。
local function placeDownloadMenu()
    for _idx, module in ipairs({
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }) do
        local search = require(module).search
        for index = #search, 1, -1 do
            if search[index] == DOWNLOAD_ITEM_ID then table.remove(search, index) end
        end
        for index, id in ipairs(search) do
            if id == "dictionary_lookup" then
                table.insert(search, index + 1, DOWNLOAD_ITEM_ID)
                break
            end
        end
    end
end

--- Book 词典开关。默认开启；关闭后完整回退 KOReader 原生词典管理。
---@return boolean
function DictInit.isEnabled()
    return MoonSettings.get("features.dictionary").dictionary_enabled
end

--- 原生查词弹窗的按钮里，月读面板已复刻的（生词本手动添加）。
local INTEGRATED_DICT_BUTTONS = { vocabulary = true }

--- 有没有别的插件往原生查词弹窗（DictQuickLookup）注册了、且月读面板没有的按钮。
--- 有就别接管这次查词：硬开月读面板等于把人家的按钮挡死，回退原生弹窗。
--- show_func 拿一个只有 word / ui 的替身试探：判不准（抛错）按会显示处理，宁可回退也不能挡。
---@param dict table ReaderDictionary 实例
---@param word string
---@return boolean
function DictInit.hasUnintegratedButtons(dict, word)
    if type(dict._dict_buttons) ~= "table" then return false end
    for id, spec in pairs(dict._dict_buttons) do
        if not INTEGRATED_DICT_BUTTONS[id] and type(spec) == "table" then
            local show = true
            if type(spec.show_func) == "function" then
                local ok, result = pcall(spec.show_func, { word = word, lookupword = word, ui = dict.ui })
                show = not ok or (result and true or false)
            end
            if show then return true end
        end
    end
    return false
end

--- 安装一次；只修改入口方法，不触碰 KOReader 源码。
function DictInit.onCreate()
    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    if ReaderDictionary._book_dict_installed then
        return
    end
    ReaderDictionary._book_dict_installed = true
    placeDownloadMenu()

    local native_show_menu = ReaderDictionary.showDictionariesMenu
    local native_add_to_main_menu = ReaderDictionary.addToMainMenu
    ReaderDictionary.showDictionariesMenu = function(self, changed_callback)
        if DictInit.isEnabled() then
            require("ui.guard").call("dictionary manage", require("features.dictionary.ui").manage, self.ui, changed_callback)
            return
        end
        return native_show_menu(self, changed_callback)
    end
    ReaderDictionary.addToMainMenu = function(self, menu_items)
        native_add_to_main_menu(self, menu_items)
        if not DictInit.isEnabled() then return end
        local settings = menu_items.dictionary_settings
        for index, item in ipairs(settings and settings.sub_item_table or {}) do
            if item.separator and type(item.sub_item_table_func) == "function" then
                table.remove(settings.sub_item_table, index)
                item.sub_item_table_func = nil
                item.separator = nil
                item.callback = require("ui.guard").wrap("dictionary download", function()
                    require("features.dictionary.ui").download(self.ui)
                end)
                menu_items[DOWNLOAD_ITEM_ID] = item
                break
            end
        end
    end

    -- 查词（划词「查词」、长按单词）改开多来源查词面板；维基百科（ReaderWikipedia 继承本类）不接管。
    local native_lookup = ReaderDictionary.onLookupWord
    ReaderDictionary.onLookupWord = function(self, word, is_sane, boxes, highlight, link, dict_close_callback)
        if not (DictInit.isEnabled() and self.ui and self.ui.dictionary == self)
            or DictInit.hasUnintegratedButtons(self, word) then
            return native_lookup(self, word, is_sane, boxes, highlight, link, dict_close_callback)
        end
        require("ui.guard").call("dictionary lookup", function()
            word = self.cleanSelection and self:cleanSelection(word, is_sane) or word
            require("features.rare.lookup").open{ ui = self.ui, text = word, source = "dict", from_highlight = highlight ~= nil,
                word_box = type(boxes) == "table" and boxes[1] or nil }
        end)
        return true
    end
end

return DictInit
