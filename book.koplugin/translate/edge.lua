--[[--
KOReader 翻译服务适配：Microsoft Edge Translate。

Edge 的响应格式与 KOReader 原有的 Google Translate 格式不同；本模块通过
插件唯一的异步 HTTP 栈请求，并保留 KOReader 的语言设置与笔记操作。

@module koplugin.book.translate.edge
--]]

require("l10n").apply()

local JSON = require("json")
local logger = require("logger")
local Text = require("utils.text")

local Edge = {
    endpoint = "https://edge.microsoft.com/translate/translatetext",
}

local LANGUAGE_MAP = {
    zh = "zh-Hans",
    zh_cn = "zh-Hans",
    zh_CN = "zh-Hans",
    ["zh-CN"] = "zh-Hans",
    zh_TW = "zh-Hant",
    zh_tw = "zh-Hant",
    ["zh-TW"] = "zh-Hant",
    iw = "he",
    tl = "fil",
    nb = "no",
}

--- KOReader 的语言代码转成 Edge 接受的代码；auto 用空 from 触发自动检测。
---@param lang string|nil
---@return string
function Edge.languageCode(lang)
    if not lang or lang == "auto" then
        return ""
    end
    return LANGUAGE_MAP[lang] or lang
end

--- 提取 Edge 数组响应的主译文与（若服务返回）识别出的源语言。
---@param payload table
---@return string|nil, string|nil
function Edge.parseResponse(payload)
    if type(payload) ~= "table" or #payload == 0 then
        return nil
    end

    local translated = {}
    local detected_lang
    for _, item in ipairs(payload) do
        local translations = item and item.translations
        local value = translations and translations[1] and translations[1].text
        if type(value) ~= "string" then
            return nil
        end
        translated[#translated + 1] = value
        if item.detectedLanguage and type(item.detectedLanguage.language) == "string" then
            detected_lang = item.detectedLanguage.language
        end
    end
    return table.concat(translated, ""), detected_lang
end

--- 异步请求 Edge；翻译 UI 运行在主事件循环，不能使用同步 Translator:loadPage。
---@param text string
---@param target_lang string
---@param source_lang string
---@param callback fun(translated: string|nil, detected_lang: string|nil, err: any)
---@return { cancel: fun() }|nil
function Edge.translateAsync(text, target_lang, source_lang, callback)
    local ok, body = pcall(JSON.encode, { text })
    if not ok or type(body) ~= "string" then
        callback(nil, nil, "JSON encode failed")
        return nil
    end
    local query = "?from=" .. Text.urlEncode(Edge.languageCode(source_lang))
        .. "&to=" .. Text.urlEncode(Edge.languageCode(target_lang))
        .. "&isEnterpriseClient=false"
    local endpoint = Edge.endpoint .. query
    logger.dbg("Calling Edge translator", endpoint)
    local Request = require("http.request")
    return Request.post(endpoint, body, {
        accept = "application/json",
        content_type = "application/json",
        connect_timeout = 30,
        timeout = 60,
    }, function(content, err)
        if err then
            callback(nil, nil, err)
            return
        end
        local decoded, payload = pcall(JSON.decode, content, JSON.decode.simple)
        if not decoded then
            logger.warn("invalid Edge translator response:", payload)
            callback(nil, nil, "invalid JSON response")
            return
        end
        local translated, detected_lang = Edge.parseResponse(payload)
        if not translated then
            callback(nil, nil, "invalid translation response")
            return
        end
        callback(translated, detected_lang)
    end)
end

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
                    text = _("Save main translation to note"),
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
                    text = _("Save all to note"),
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
                    text = _("Copy main translation"),
                    callback = function()
                        Device.input.setClipboardText(translated)
                    end,
                },
                {
                    text = _("Copy all"),
                    callback = function()
                        Device.input.setClipboardText(text_all)
                    end,
                },
            }
        end
    end

    local source_name = translator:getLanguageName(source_lang == "auto" and nil or source_lang, "?")
    textviewer = TextViewer:new{
        title = T(_("Translation from %1"), source_name),
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

--- 使用 Edge 的异步翻译入口，保留 KOReader 的联网恢复与剪贴板行为。
function Edge.showTranslation(translator, text, detailed_view, source_lang, target_lang, from_highlight, index)
    local Device = require("device")
    if Device:hasClipboard() then
        Device.input.setClipboardText(text)
    end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:willRerunWhenOnline(function()
        Edge.showTranslation(translator, text, detailed_view, source_lang, target_lang, from_highlight, index)
    end) then
        return
    end
    target_lang = target_lang or translator:getTargetLanguage()
    source_lang = source_lang or translator:getSourceLanguage()
    Edge.translateAsync(text, target_lang, source_lang, function(translated, detected_lang, err)
        if not translated then
            logger.warn("Edge translator failed:", err)
            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                text = require("gettext")("Translation failed."),
            })
            return
        end
        showResult(translator, text, translated, detailed_view, detected_lang or source_lang, from_highlight, index)
    end)
end

--- 全局替换 KOReader 的用户翻译入口；重复调用无副作用。
function Edge.install()
    local Translator = require("ui/translator")
    if Translator._book_edge_translation then
        return
    end
    Translator._book_edge_translation = true
    Translator.showTranslation = function(self, text, detailed_view, source_lang, target_lang, from_highlight, index)
        return Edge.showTranslation(self, text, detailed_view, source_lang, target_lang, from_highlight, index)
    end
end

return Edge
