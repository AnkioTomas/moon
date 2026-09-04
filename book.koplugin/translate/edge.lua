--[[--
Microsoft Edge 翻译传输：供 KOReader 翻译 UI 使用。

请求必须走插件统一的异步 HTTP 栈；不能在 Translator 的 Trapper 子进程
里调用 UI 主循环异步接口，也不能重新引入 socket.http。

@module koplugin.book.translate.edge
--]]

local JSON = require("json")
local logger = require("utils.log")
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

--- KOReader 语言码 → Edge；auto / nil → 空 from。
---@param lang string|nil
---@return string
function Edge.languageCode(lang)
    if not lang or lang == "auto" then
        return ""
    end
    return LANGUAGE_MAP[lang] or lang
end

--- 解析 Edge JSON 数组 → 译文, 检测语言。
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

--- 异步请求 Edge。
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
    local endpoint = Edge.endpoint
        .. "?from=" .. Text.urlEncode(Edge.languageCode(source_lang))
        .. "&to=" .. Text.urlEncode(Edge.languageCode(target_lang))
        .. "&isEnterpriseClient=false"
    logger.dbg("Calling Edge translator", endpoint)
    local Request = require("http.request")
    return Request.post(endpoint, body, {
        accept = "application/json",
        content_type = "application/json",
        connect_timeout = 30,
        timeout = 60,
    }, function(content, err)
        if err then
            logger.warn("book.translate edge failed", err)
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
            logger.warn("invalid Edge translator payload")
            callback(nil, nil, "invalid translation response")
            return
        end
        callback(translated, detected_lang)
    end)
end

return Edge
