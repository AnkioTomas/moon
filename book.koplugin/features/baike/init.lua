--[[--
把 KOReader 的 Wikipedia 查询入口换成多来源查词面板的「百科」栏。

保留原有事件名和按钮 id，已有手势、划词菜单显隐配置仍然有效；只替换传输
与结果，不把百度百科硬包装成可切语言、可导 EPUB 的维基百科。

@module koplugin.book.features.baike.init
--]]

require("l10n").apply()

local logger = require("utils.log")
local _ = require("gettext")
local MoonSettings = require("utils.settings")

local Baike = {}

--- 百度百科开关。默认开启；关闭后完整回退 KOReader 原生维基百科。
---@return boolean
function Baike.isEnabled()
    return MoonSettings.get("features.baike").baike_enabled
end

--- 百科查询一律开多来源查词面板，停在「百科」栏（联网、取消、未收录由面板处理）。
---@param self table ReaderWikipedia 实例
---@param word string
---@param is_sane boolean|nil
---@param box table|nil
local function lookup(self, word, is_sane, box)
    word = self:cleanSelection(word, is_sane)
    if word == "" then return end
    logger.dbg("Baidu Baike lookup:", word)
    local highlight = self.ui and self.ui.highlight
    require("features.rare.lookup").open{
        ui = self.ui, text = word, source = "baike",
        from_highlight = highlight ~= nil and highlight.selected_text ~= nil,
        word_box = type(box) == "table" and (box[1] or box) or nil,
    }
end

---@param self table ReaderWikipedia 实例
local function lookupInput(self)
    require("ui.themes.widgets.input"):new{
        title = _("百度百科查询"),
        fields = { { text = "" } },
        ok_text = _("百度百科查询"),
        callback = function(word)
            if word ~= "" then self:onLookupWikipedia(word, true) end
        end,
    }:show()
end

local native_long_press_text

--- 长按动作菜单在建菜单时读文字，每次插件创建按当前开关重写一次。
local function relabelLongPress()
    for _idx, action in ipairs(require("apps/reader/modules/readerhighlight").long_press_action) do
        if action[2] == "wikipedia" then
            native_long_press_text = native_long_press_text or action[1]
            action[1] = Baike.isEnabled() and _("百度百科") or native_long_press_text
        end
    end
end

--- 安装一次；只修改 KOReader 的入口方法，不触碰其源码。
function Baike.onCreate()
    relabelLongPress()
    local ReaderWikipedia = require("apps/reader/modules/readerwikipedia")
    if ReaderWikipedia._book_baike_installed then
        return
    end
    ReaderWikipedia._book_baike_installed = true
    local native_lookup = ReaderWikipedia.lookupWikipedia
    local native_lookup_input = ReaderWikipedia.lookupInput
    local native_add_to_main_menu = ReaderWikipedia.addToMainMenu
    ReaderWikipedia.lookupWikipedia = function(self, ...)
        if Baike.isEnabled() then
            return require("ui.guard").call("baike lookup", lookup, self, ...)
        end
        return native_lookup(self, ...)
    end
    ReaderWikipedia.lookupInput = function(self, ...)
        if Baike.isEnabled() then
            return require("ui.guard").call("baike input", lookupInput, self)
        end
        return native_lookup_input(self, ...)
    end
    ReaderWikipedia.addToMainMenu = function(self, menu_items)
        if not Baike.isEnabled() then
            return native_add_to_main_menu(self, menu_items)
        end
        -- 保留 wikipedia_lookup 键，KOReader 的菜单排序和用户现有配置无需迁移。
        menu_items.wikipedia_lookup = {
            text = _("百度百科查询"),
            callback = function()
                self:onShowWikipediaLookup()
            end,
        }
    end

    local DictQuickLookup = require("ui/widget/dictquicklookup")
    local original_button_pool = DictQuickLookup._getButtonPool
    DictQuickLookup._getButtonPool = function(self)
        local pool = original_button_pool(self)
        if Baike.isEnabled() and pool.wikipedia then
            pool.wikipedia.text = _("百度百科")
            pool.wikipedia.text_func = nil
        end
        return pool
    end

    -- 手势、快捷菜单、配置档的显示名；动作选择列表直读局部 settingsList，改不到。
    local Dispatcher = require("dispatcher")
    local native_name = Dispatcher.getNameFromItem
    Dispatcher.getNameFromItem = function(self, item, ...)
        if item == "wikipedia_lookup" and Baike.isEnabled() then
            return _("百度百科查询")
        end
        return native_name(self, item, ...)
    end
end

return Baike
