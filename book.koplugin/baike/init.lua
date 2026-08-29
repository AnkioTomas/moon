--[[--
把 KOReader 的 Wikipedia 查询入口换成百度百科卡片。

保留原有事件名和按钮 id，已有手势、划词菜单显隐配置仍然有效；只替换传输
与结果，不把百度百科硬包装成可切语言、可导 EPUB 的维基百科。

@module koplugin.book.baike.init
--]]

local l10n = require("l10n")
if l10n.apply then
    l10n.apply()
end

local Client = require("baike.client")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local MoonSettings = require("utils.settings")

local Baike = {}

--- 百度百科开关。默认开启；关闭后完整回退 KOReader 原生维基百科。
---@return boolean
function Baike.isEnabled()
    return MoonSettings.get("reader").baike_enabled ~= false
end

---@param self table ReaderWikipedia 实例
---@param word string
---@param result { title: string, definition: string }|nil
---@param err string|nil
---@param box table|nil
---@param dict_close_callback function|nil
---@return nil
local function showResult(self, word, result, err, box, dict_close_callback)
    -- ReaderWikipedia 继承 ReaderDictionary。仅在构造弹窗的同步片刻切为普通
    -- 词典，便可复用它完整的样式、关闭和高亮行为，而不会带出 Wiki 专用按钮。
    local previous_is_wiki = self.is_wiki
    self.is_wiki = false
    local definition
    local title = word
    if result then
        title = result.title
        definition = result.definition
    elseif err == "not found" then
        definition = _("百度百科未找到相关词条。")
    else
        definition = T(_("百度百科暂不可用：%1"), tostring(err or _("未知错误")))
    end
    local ok, show_err = pcall(self.showDict, self, word, {
        {
            dict = _("百度百科"),
            word = title,
            definition = definition,
        },
    }, box, nil, dict_close_callback)
    self.is_wiki = previous_is_wiki
    if not ok then
        error(show_err, 0)
    end
end

---@param self table ReaderWikipedia 实例
---@param word string
---@param is_sane boolean|nil
---@param box table|nil
---@param _get_fullpage boolean|nil
---@param _forced_lang string|nil
---@param dict_close_callback function|nil
---@return nil
local function lookup(self, word, is_sane, box, _get_fullpage, _forced_lang, dict_close_callback)
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:willRerunWhenOnline(function()
        lookup(self, word, is_sane, box, nil, nil, dict_close_callback)
    end) then
        return
    end
    word = self:cleanSelection(word, is_sane)
    if word == "" then
        return
    end
    logger.dbg("Baidu Baike lookup:", word)
    self.lookup_msg = _("正在查询百度百科：\n%1")
    self:showLookupInfo(word)
    local previous = self._book_baike_job
    if previous and previous.job and previous.job.cancel then
        previous.job:cancel()
    end
    -- Request 在生产环境异步回调，但测试替身和失败路径可能同步回调；用请求状态
    -- 对象而非返回的 job 比较，二者都正确。
    local state = {}
    self._book_baike_job = state
    state.job = Client.lookupAsync(word, function(result, err)
        if self._book_baike_job ~= state then
            return
        end
        self._book_baike_job = nil
        showResult(self, word, result, err, box, dict_close_callback)
    end)
end

---@param self table ReaderWikipedia 实例
---@return nil
local function lookupInput(self)
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")
    self.input_dialog = InputDialog:new{
        title = _("百度百科查询"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.input_dialog)
                    end,
                },
                {
                    text = _("百度百科查询"),
                    is_enter_default = true,
                    callback = function()
                        local word = self.input_dialog:getInputText()
                        if word == "" then
                            return
                        end
                        UIManager:close(self.input_dialog)
                        self:onLookupWikipedia(word, true)
                    end,
                },
            },
        },
    }
    UIManager:show(self.input_dialog)
    self.input_dialog:onShowKeyboard()
end

--- 安装一次；只修改 KOReader 的入口方法，不触碰其源码。
---@return nil
function Baike.install()
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
            return lookup(self, ...)
        end
        return native_lookup(self, ...)
    end
    ReaderWikipedia.lookupInput = function(self, ...)
        if Baike.isEnabled() then
            return lookupInput(self, ...)
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
end

return Baike
