--[[--
翻译语言列表与设置持久化。

语言表来自 KOReader `ui/translator` 的 SUPPORTED_LANGUAGES（经 getLanguageName
闭包读取），避免在本插件复制 200+ 语言项。弹窗语言选择优先读
reader.translate_languages；「全部语言…」才展开完整列表。

@module koplugin.book.translate.languages
--]]

require("l10n").apply()

local MoonSettings = require("utils.settings")
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local Languages = {}

local ALL_LANGUAGES = "__all__"

local DEFAULT_FAVORITES = { "en", "zh", "ja", "fr", "de", "ko", "es", "ru", "zh_TW" }

local FALLBACK = {
    en = "English",
    zh = "Chinese (Simplified)",
    zh_TW = "Chinese (Traditional)",
    ja = "Japanese",
    fr = "French",
    de = "German",
    es = "Spanish",
    ko = "Korean",
    ru = "Russian",
}

-- 键一律小写，查表前先 lower。
local DETECTED_ALIASES = {
    ["zh-hans"] = "zh",
    ["zh-hant"] = "zh_TW",
}

--- Edge / API 语言码 → KOReader 语言码。
---@param code string
---@return string
local function normalizeCode(code)
    return DETECTED_ALIASES[code:lower()] or code
end

---@param translator table
---@return table<string, string>
local function supportedMap(translator)
    local fn = translator and translator.getLanguageName
    if type(fn) == "function" then
        for i = 1, 64 do
            local name, value = debug.getupvalue(fn, i)
            if name == "SUPPORTED_LANGUAGES" and type(value) == "table" then
                return value
            end
        end
    end
    return FALLBACK
end

--- 语言展示名。
---@param translator table
---@param code string
---@return string
local function languageName(translator, code)
    local map = supportedMap(translator)
    if map[code] then
        return map[code]
    end
    return translator:getLanguageName(code, code)
end

--- 常用语言代码（settings 未配置时用 defaults）。
---@return string[]
function Languages.favoriteCodes()
    local list = MoonSettings.get("reader").translate_languages
    if type(list) == "table" and #list > 0 then
        return list
    end
    return DEFAULT_FAVORITES
end

--- 写入常用语言。
---@param codes string[]
function Languages.saveFavorites(codes)
    local reader = MoonSettings.get("reader")
    reader.translate_languages = codes
    MoonSettings.saveSection("reader", reader)
end

--- 打开设置页：常用翻译语言多选（完整语言列表，已选中常用语言）。
---@param translator table
---@param desktop table|nil
function Languages.openSettingsPicker(translator, desktop)
    local favorites = {}
    for _, code in ipairs(Languages.favoriteCodes()) do
        favorites[code] = true
    end
    local items = {}
    for code, name in ffiUtil.orderedPairs(supportedMap(translator)) do
        items[#items + 1] = {
            text = name,
            value = code,
            checked = favorites[code] == true,
        }
    end
    require("ui.views.popup").multi{
        title = _("常用翻译语言"),
        subtitle = _("划词翻译时优先显示这些语言"),
        items = items,
        close_callback = function()
            local codes = {}
            for _, item in ipairs(items) do
                if item.checked and item.value then
                    codes[#codes + 1] = item.value
                end
            end
            Languages.saveFavorites(codes)
            if desktop and desktop.updateView then
                desktop:updateView()
            end
        end,
    }
end

--- 弹窗语言选择项：常用 + 当前 + 全部语言入口。
---@param translator table
---@param include_auto boolean|nil
---@param current string|nil
---@return table[]
function Languages.pickerItems(translator, include_auto, current)
    local items = {}
    local seen = {}
    --- 追加一个语言项，重复代码按先到先得去重。
    ---@param code string|nil 语言代码，nil 直接跳过
    ---@param text string|nil 显示文案，缺省取语言本地化名
    local function add(code, text)
        if not code or seen[code] then
            return
        end
        seen[code] = true
        items[#items + 1] = {
            text = text or languageName(translator, code),
            value = code,
        }
    end
    if include_auto then
        add("auto", _("自动检测"))
    end
    for _, code in ipairs(Languages.favoriteCodes()) do
        add(code)
    end
    if current and not seen[current] then
        add(current)
    end
    items[#items + 1] = { text = _("全部语言…"), value = ALL_LANGUAGES }
    return items
end

--- 全部语言（不含「全部语言…」入口）。
---@param translator table
---@param include_auto boolean|nil
---@return table[]
function Languages.allItems(translator, include_auto)
    local items = {}
    if include_auto then
        items[#items + 1] = { text = _("自动检测"), value = "auto" }
    end
    for code, name in ffiUtil.orderedPairs(supportedMap(translator)) do
        items[#items + 1] = { text = name, value = code }
    end
    return items
end

--- 展示用语言名；auto 时优先 detected，否则「自动检测」。
---@param translator table
---@param code string|nil
---@param detected string|nil
---@return string
function Languages.displayName(translator, code, detected)
    if code == "auto" then
        if type(detected) ~= "string" then
            return _("自动检测")
        end
        return languageName(translator, normalizeCode(detected))
    end
    if type(code) ~= "string" then
        return "?"
    end
    return languageName(translator, normalizeCode(code))
end

--- 写入 KOReader 源语言设置。
---@param code string
function Languages.applySource(code)
    if code == "auto" then
        G_reader_settings:saveSetting("translator_from_auto_detect", true)
        return
    end
    G_reader_settings:saveSetting("translator_from_auto_detect", false)
    G_reader_settings:saveSetting("translator_from_language", code)
end

--- 写入 KOReader 目标语言设置。
---@param code string
function Languages.applyTarget(code)
    G_reader_settings:saveSetting("translator_to_language", code)
end

Languages.ALL_LANGUAGES = ALL_LANGUAGES

return Languages
