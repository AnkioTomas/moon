--[[--
核心翻译：按 KOReader 当前语言加载 l10n/{lang}.lua，合并进 gettext。
书源通过 get("source.<id>") 读取自己的 l10n/{lang}.lua，不写全局 gettext。
源字符串是简体中文；zh_CN / zh 不覆盖。
其它语言找不到目录时回落到 en。
语言切换后 KOReader 会要求重启，加载一次即可。

@module koplugin.book.l10n
--]]

local GetText = require("gettext")

local M = {}
local applied_for

--- 是否繁体中文语言码（zh_TW / zh_HK）
---@param lang string
---@return string|nil
local function isTraditionalChinese(lang)
    return lang:match("^zh_TW") or lang:match("^zh_HK")
end

--- 按当前语言生成待加载的 l10n 目录候选列表
---@param lang string|nil
---@return string[]
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

--- 当前语言对应的目录：返回目录名（"en" / "zh_TW" / …；简体中文为 "zh_CN"）与译文表。
--- 远程管理网页经 /api/i18n 取用（再合并 features/remote/l10n/web），与 KOReader 界面语言保持一致。
---@param lang string|nil 缺省取 KOReader 当前语言
---@param owner string|nil 缺省为核心目录；书源传 source.<id>
---@return string name
---@return table catalog 源文（简体中文）→ 译文；简体中文为空表
function M.catalog(lang, owner)
    lang = lang or GetText.current_lang or "C"
    local list = candidates(lang)
    if #list == 0 then
        return "zh_CN", {}
    end
    for _idx, cand in ipairs(list) do
        local module = (owner and owner .. "." or "") .. "l10n." .. cand
        local ok, catalog = pcall(require, module)
        if not ok and not tostring(catalog):find("module '" .. module .. "' not found:", 1, true) then
            error(catalog, 0)
        end
        if ok then
            assert(type(catalog) == "table", module .. " must return a translation table")
            return cand, catalog
        end
    end
    return "zh_CN", {}
end

--- 书源独立翻译；共享文案与未知文案仍交给 KOReader gettext。
---@param owner string
---@return fun(msgid: string): string
function M.get(owner)
    local _name, catalog = M.catalog(nil, owner)
    return function(msgid)
        return catalog[msgid] or GetText(msgid)
    end
end

--- 按 KOReader 当前语言加载翻译并合并进 gettext（同语言只做一次）
function M.apply()
    local lang = GetText.current_lang or "C"
    if applied_for == lang then
        return
    end
    local _name, catalog = M.catalog(lang)
    for msgid, msgstr in pairs(catalog) do
        if type(msgid) == "string" and type(msgstr) == "string" and msgstr ~= "" then
            GetText.translation[msgid] = msgstr
        end
    end
    applied_for = lang
end

M.apply()
return M
