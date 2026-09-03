--[[--
把 KOReader 原生词典管理换成 Book 词典下载/切换。

保留查词事件与划词按钮；开启时接管「管理词典 / 下载词典」菜单，
查词弹窗点标题栏可切换词典（对齐翻译弹窗切语言）。关闭后完整回退原生。

@module koplugin.book.dictionary.init
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")

local DictInit = {}
local DOWNLOAD_ITEM_ID = "dictionary_download"

--- 把下载入口排在查词之后；菜单项本身由 ReaderDictionary.addToMainMenu 提供。
---@return nil
local function placeDownloadMenu()
    for _, module in ipairs({
        "ui/elements/reader_menu_order",
        "ui/elements/filemanager_menu_order",
    }) do
        local ok, order = pcall(require, module)
        local search = ok and order.search
        if type(search) == "table" then
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
end

--- Book 词典开关。默认开启；关闭后完整回退 KOReader 原生词典管理。
---@return boolean
function DictInit.isEnabled()
    return MoonSettings.get("reader").dictionary_enabled ~= false
end

--- 安装一次；只修改入口方法，不触碰 KOReader 源码。
---@return nil
function DictInit.install()
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
            require("ui.reader.dictionary").manage(self.ui, changed_callback)
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
                item.callback = function()
                    require("ui.reader.dictionary").download(self.ui)
                end
                menu_items[DOWNLOAD_ITEM_ID] = item
                break
            end
        end
    end

    local DictQuickLookup = require("ui/widget/dictquicklookup")
    local native_on_tap = DictQuickLookup.onTap
    local native_change = DictQuickLookup.changeDictionary
    -- 标题追加 ▼，提示可点按切换（对齐翻译语言按钮）。
    DictQuickLookup.changeDictionary = function(self, index, skip_update)
        if not self.results or not self.results[index] then return end
        native_change(self, index, true)
        if DictInit.isEnabled() and not self.is_wiki
            and type(self.displaydictname) == "string"
            and self.displaydictname ~= ""
            and not self.displaydictname:find("▼", 1, true) then
            self.displaydictname = self.displaydictname .. " ▼"
        end
        if not skip_update then
            self:update()
        end
    end
    -- 点标题栏：切词典并重查当前词（关闭时回退原生「偏好词典」切换）。
    DictQuickLookup.onTap = function(self, arg, ges_ev)
        if DictInit.isEnabled() and not self.is_wiki
            and self.dict_title and self.dict_title.dimen
            and ges_ev and ges_ev.pos and ges_ev.pos.intersectWith
            and ges_ev.pos:intersectWith(self.dict_title.dimen) then
            require("ui.reader.dictionary").pick(self.ui, {
                word = self.word,
                current_name = self.dictionary,
                close_window = function()
                    self:onClose(true)
                end,
            })
            return true
        end
        return native_on_tap(self, arg, ges_ev)
    end
end

return DictInit
