--[[--
插件翻译：按 KOReader 当前语言加载 l10n/{lang}.lua，合并进 gettext。
源字符串是简体中文；zh_CN / zh 不覆盖。
其它语言找不到目录时回落到 en。
语言切换后 KOReader 会要求重启，加载一次即可。

@module koplugin.book.l10n
--]]

local GetText = require("gettext")
local logger = require("logger")

local M = {}
local applied_for

local function isTraditionalChinese(lang)
    return lang:match("^zh_TW") or lang:match("^zh_HK")
end

local function candidates(lang)
    lang = tostring(lang or "")
    lang = lang:gsub("%.utf8$", ""):gsub("%.UTF%-8$", "")
    if lang == "" or lang == "C" or lang:match("^en") then
        return { "en" }
    end
    if isTraditionalChinese(lang) then
        return { "zh_TW" }
    end
    -- 源字符串就是简体中文
    if lang:match("^zh") then
        return {}
    end
    local out = { lang }
    local base = lang:match("^([^_]+)")
    if base and base ~= lang then
        table.insert(out, base)
    end
    table.insert(out, "en")
    return out
end

function M.apply()
    local lang = GetText.current_lang or "C"
    if applied_for == lang then
        return
    end
    applied_for = lang
    for _, cand in ipairs(candidates(lang)) do
        local ok, catalog = pcall(require, "l10n." .. cand)
        if ok and type(catalog) == "table" then
            for msgid, msgstr in pairs(catalog) do
                if type(msgid) == "string" and type(msgstr) == "string" and msgstr ~= "" then
                    GetText.translation[msgid] = msgstr
                end
            end
            logger.dbg("book.l10n loaded", cand, "for", lang)
            return
        end
    end
end

M.apply()
return M
