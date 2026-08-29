--[[--
翻译注入：把 Edge 请求接入 KOReader 的翻译 UI。

Edge 请求和插件行为分开：`translate.edge` 只负责传输与响应解析，
本模块负责联网恢复与 Translator 注入；弹窗见 translate.popup。

@module koplugin.book.translate.init
--]]

require("l10n").apply()

local Popup = require("translate.popup")
local MoonSettings = require("utils.settings")
local Translate = {}

--- Edge 翻译开关。默认开启；关闭后完整回退 KOReader 原生翻译实现。
---@return boolean
function Translate.isEnabled()
    return MoonSettings.get("reader").edge_translation_enabled ~= false
end

--- 复制原文到剪贴板，确保联网后打开 Edge 翻译弹窗。
--- 离线时交给 NetworkMgr 排队，联网回调里重跑本函数，因此参数需原样透传。
---@param translator table KOReader Translator 单例
---@param text string 待翻译原文
---@param detailed_view boolean|nil 原生详细模式标记，本实现不使用
---@param source_lang string|nil 源语言代码，缺省取 translator 当前设置
---@param target_lang string|nil 目标语言代码，缺省取 translator 当前设置
---@param from_highlight boolean|nil 是否由划词菜单触发（决定是否显示存笔记按钮）
---@param index number|nil 划词笔记序号，有值则编辑该条而非新增
local function showTranslation(translator, text, detailed_view, source_lang, target_lang, from_highlight, index)
    local Device = require("device")
    if Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:willRerunWhenOnline(function()
        showTranslation(translator, text, detailed_view, source_lang, target_lang, from_highlight, index)
    end) then
        return
    end
    Popup.open{
        translator = translator,
        text = text,
        source_lang = source_lang or translator:getSourceLanguage(),
        target_lang = target_lang or translator:getTargetLanguage(),
        from_highlight = from_highlight,
        index = index,
    }
end

--- 安装 Edge 翻译入口；重复调用无副作用。
function Translate.install()
    local Translator = require("ui/translator")
    if Translator._book_edge_translation then
        return
    end
    Translator._book_edge_translation = true
    local native_show_translation = Translator.showTranslation
    Translator.showTranslation = function(self, text, detailed_view, source_lang, target_lang, from_highlight, index)
        if not Translate.isEnabled() then
            return native_show_translation(self, text, detailed_view, source_lang, target_lang, from_highlight, index)
        end
        return showTranslation(self, text, detailed_view, source_lang, target_lang, from_highlight, index)
    end
end

return Translate
