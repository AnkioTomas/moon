--[[--
翻译注入：把 Edge 请求接入 KOReader 的翻译 UI。

Edge 请求和插件行为分开：`translate.edge` 只负责传输与响应解析，
本模块负责联网恢复、提示框、结果窗口和 Translator 注入。

@module koplugin.book.translate.init
--]]

require("l10n").apply()

local Edge = require("translate.edge")
local logger = require("logger")
local Translate = {}

local function showResult(translator, text, translated, detailed_view, source_lang, from_highlight, index)
    local Device = require("device")
    local Screen = Device.screen
    local TextViewer = require("ui/widget/textviewer")
    local UIManager = require("ui/uimanager")
    local T = require("ffi/util").template
    local _ = require("gettext")

    local text_all = translated
    if detailed_view then
        text_all = "▣ " .. text .. "\n● " .. translated
    end
    local buttons_table
    local close_callback
    local textviewer
    if detailed_view then
        buttons_table = {}
        if from_highlight then
            local ui = require("apps/reader/readerui").instance
            buttons_table[#buttons_table + 1] = {
                {
                    text = _("保存主要翻译到笔记"),
                    callback = function()
                        UIManager:close(textviewer)
                        UIManager:close(ui.highlight.highlight_dialog)
                        ui.highlight.highlight_dialog = nil
                        if index then
                            ui.highlight:editNote(index, false, translated)
                        else
                            ui.highlight:addNote(translated)
                        end
                    end,
                },
                {
                    text = _("保存全部内容到笔记"),
                    callback = function()
                        UIManager:close(textviewer)
                        UIManager:close(ui.highlight.highlight_dialog)
                        ui.highlight.highlight_dialog = nil
                        if index then
                            ui.highlight:editNote(index, false, text_all)
                        else
                            ui.highlight:addNote(text_all)
                        end
                    end,
                },
            }
            close_callback = function()
                if not ui.highlight.highlight_dialog then
                    ui.highlight:clear()
                end
            end
        end
        if Device:hasClipboard() then
            buttons_table[#buttons_table + 1] = {
                {
                    text = _("复制主要翻译"),
                    callback = function()
                        Device.input.setClipboardText(translated)
                    end,
                },
                {
                    text = _("复制全部内容"),
                    callback = function()
                        Device.input.setClipboardText(text_all)
                    end,
                },
            }
        end
    end

    local source_name = translator:getLanguageName(source_lang == "auto" and nil or source_lang, "?")
    textviewer = TextViewer:new{
        title = T(_("翻译来源：%1"), source_name),
        title_multilines = true,
        text = text_all,
        text_type = "lookup",
        height = detailed_view and math.floor(Screen:getHeight() * 0.8) or nil,
        add_default_buttons = true,
        buttons_table = buttons_table,
        close_callback = close_callback,
    }
    UIManager:show(textviewer)
end

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
    target_lang = target_lang or translator:getTargetLanguage()
    source_lang = source_lang or translator:getSourceLanguage()
    Edge.translateAsync(text, target_lang, source_lang, function(translated, detected_lang, err)
        if not translated then
            local _ = require("gettext")
            local UIManager = require("ui/uimanager")
            local InfoMessage = require("ui/widget/infomessage")
            logger.warn("Edge translator failed:", err)
            UIManager:show(InfoMessage:new{ text = _("翻译失败") })
            return
        end
        showResult(translator, text, translated, detailed_view,
            detected_lang or source_lang, from_highlight, index)
    end)
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
