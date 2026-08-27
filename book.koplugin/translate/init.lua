--[[--
翻译注入：把 Edge 请求接入 KOReader 的翻译 UI。

Edge 请求和插件行为分开：`translate.edge` 只负责传输与响应解析，
本模块负责联网恢复与 Translator 注入；弹窗见 translate.popup。

@module koplugin.book.translate.init
--]]

require("l10n").apply()

local Popup = require("translate.popup")
local Translate = {}

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
    Translator.showTranslation = function(self, text, detailed_view, source_lang, target_lang, from_highlight, index)
        return showTranslation(self, text, detailed_view, source_lang, target_lang, from_highlight, index)
    end
end

return Translate
