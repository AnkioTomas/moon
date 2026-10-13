--[[--
翻译注入：把 Edge 请求接入 KOReader 的翻译 UI。

Edge 请求和插件行为分开：`features.translate.edge` 只负责传输与响应解析，
本模块负责联网恢复与 Translator 注入；弹窗见 features.translate.popup。

@module koplugin.book.features.translate.init
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")
local Translate = {}

--- Edge 翻译开关。默认开启；关闭后完整回退 KOReader 原生翻译实现。
---@return boolean
function Translate.isEnabled()
    return MoonSettings.get("features.translate").edge_translation_enabled
end

--- 复制原文到剪贴板，确保连上网后打开 Edge 翻译弹窗。
--- 未连网时交给 NetworkMgr 询问开 Wi-Fi，连上后重跑本函数，因此参数需原样透传。
--- 只认 isConnected：原生用的 willRerunWhenOnline 走同步 DNS，会卡界面，
--- 且「已连 Wi-Fi 但 DNS 不通」时既不弹窗也不回调；请求失败由弹窗显示原因。
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
    if NetworkMgr:willRerunWhenConnected(function()
        showTranslation(translator, text, detailed_view, source_lang, target_lang, from_highlight, index)
    end) then
        return
    end
    require("features.translate.popup").open{
        translator = translator,
        text = text,
        source_lang = source_lang or translator:getSourceLanguage(),
        target_lang = target_lang or translator:getTargetLanguage(),
        full_page = detailed_view == false,
        from_highlight = from_highlight,
        index = index,
    }
end

--- 安装 Edge 翻译入口；重复调用无副作用。
function Translate.onCreate()
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
        return require("ui.guard").call("edge translate", showTranslation, self, text, detailed_view, source_lang, target_lang, from_highlight, index)
    end
end

return Translate
