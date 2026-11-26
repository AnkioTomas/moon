--[[--
静态解析插件目录里的 `_meta.lua`：只抽字面量，不 load、不 loadstring、不执行远程 Lua。

支持常见写法：name 字面量、gettext 源文字面量、["name"] 字面量, 以及 `zh` / `zh_CN` /
`zh_TW` / `l10n` 子表里的标题和简介。gettext 字面量按源文展示；不臆造翻译。

@module koplugin.book.features.marketplace.meta
--]]

local Meta = {}

Meta.FILENAME = "_meta.lua"

local DISPLAY_KEYS = {
    name = true, fullname = true, title = true, description = true, version = true,
    name_zh = true, fullname_zh = true, title_zh = true, description_zh = true,
}

local LOCALE_KEYS = {
    zh = true, zh_CN = true, zh_cn = true, zh_TW = true, zh_tw = true,
    l10n = true, i18n = true, translations = true,
}

local function isCjk(text)
    return type(text) == "string" and text:find("[\228-\233][\128-\191][\128-\191]") ~= nil
end

---@param text string
---@param i integer
---@return integer
local function skip(text, i)
    local n = #text
    while i <= n do
        local ch = text:sub(i, i)
        if ch == " " or ch == "\t" or ch == "\r" or ch == "\n" then
            i = i + 1
        elseif ch == "-" and text:sub(i + 1, i + 1) == "-" then
            if text:sub(i + 2, i + 3) == "[[" then
                local close = text:find("%]%]", i + 4)
                i = close and (close + 2) or (n + 1)
            else
                local close = text:find("\n", i + 2)
                i = close and (close + 1) or (n + 1)
            end
        else
            break
        end
    end
    return i
end

---@param text string
---@param i integer
---@return string|nil
---@return integer
local function parseLongString(text, i)
    local eq = text:match("^%[(=*)%[", i)
    if not eq then return nil, i end
    local open = "[" .. eq .. "["
    local close = "]" .. eq .. "]"
    local start = i + #open
    local finish = text:find(close, start, true)
    if not finish then return nil, i end
    return text:sub(start, finish - 1), finish + #close
end

---@param text string
---@param i integer
---@return string|nil
---@return integer
local function parseQuoted(text, i)
    local quote = text:sub(i, i)
    if quote ~= "'" and quote ~= '"' then return nil, i end
    local n = #text
    local out, j = {}, i + 1
    while j <= n do
        local ch = text:sub(j, j)
        if ch == "\\" then
            local nxt = text:sub(j + 1, j + 1)
            local map = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }
            out[#out + 1] = map[nxt] or nxt
            j = j + 2
        elseif ch == quote then
            return table.concat(out), j + 1
        else
            out[#out + 1] = ch
            j = j + 1
        end
    end
    return nil, i
end

---@param text string
---@param i integer
---@return string|nil
---@return integer
local function parseString(text, i)
    i = skip(text, i)
    if text:sub(i, i) == "_" and text:sub(i + 1, i + 1) == "(" then
        local inner, nxt = parseString(text, skip(text, i + 2))
        if not inner then return nil, i end
        nxt = skip(text, nxt)
        if text:sub(nxt, nxt) == ")" then
            return inner, nxt + 1
        end
        return nil, i
    end
    if text:sub(i, i) == "[" then
        return parseLongString(text, i)
    end
    return parseQuoted(text, i)
end

---@param text string
---@param i integer
---@return string|nil
---@return integer
local function parseKey(text, i)
    i = skip(text, i)
    if text:sub(i, i) == "[" then
        local key, nxt = parseString(text, skip(text, i + 1))
        if not key then return nil, i end
        nxt = skip(text, nxt)
        if text:sub(nxt, nxt) == "]" then
            return key, nxt + 1
        end
        return nil, i
    end
    local key = text:match("^([%a_][%w_]*)", i)
    if key then return key, i + #key end
    return nil, i
end

---@param text string
---@param i integer
---@param depth integer
---@return table|nil
---@return integer
local function parseTable(text, i, depth)
    i = skip(text, i)
    if text:sub(i, i) ~= "{" then return nil, i end
    i = i + 1
    local out = {}
    local n = #text
    while i <= n do
        i = skip(text, i)
        local ch = text:sub(i, i)
        if ch == "" or ch == "}" then
            return out, i + 1
        end
        if ch == "," or ch == ";" then
            i = i + 1
        else
            local key, after_key = parseKey(text, i)
            if not key then return out, i end
            after_key = skip(text, after_key)
            if text:sub(after_key, after_key) ~= "=" then
                -- 不解析数组项，跳过到下一个分隔符会很脆弱；到此为止已经够用。
                return out, after_key
            end
            local after_eq = skip(text, after_key + 1)
            if text:sub(after_eq, after_eq) == "{" and depth < 3 then
                local nested, nxt = parseTable(text, after_eq, depth + 1)
                if nested and (LOCALE_KEYS[key] or key:match("^zh")) then
                    out[key] = nested
                end
                i = nxt or (after_eq + 1)
            else
                local value, nxt = parseString(text, after_eq)
                if value and (DISPLAY_KEYS[key] or depth > 0) then
                    out[key] = value
                end
                i = nxt or (after_eq + 1)
                if not value then
                    -- 跳过非字符串值（函数、数字等），以免卡住。
                    local stop = text:find("[,;}]", after_eq)
                    i = stop or (n + 1)
                end
            end
        end
    end
    return out, i
end

--- 解析 `_meta.lua` 文本。失败返回 nil, err，不抛错。
---@param text string|nil
---@return table|nil
---@return string|nil
function Meta.parse(text)
    if type(text) ~= "string" or text:match("^%s*$") then
        return nil, "empty"
    end
    local start = text:find("return%s*{")
    local body = start and text:match("return%s*", start)
    local parsed
    if start then
        local brace = text:find("{", start, true)
        parsed = brace and parseTable(text, brace, 0) or nil
    end
    if not parsed or (parsed.name == nil and parsed.fullname == nil and parsed.title == nil
        and parsed.version == nil and parsed.description == nil) then
        -- 兜底：在全文里抓已知字段的字面量（仍不执行）。
        parsed = parsed or {}
        for key in pairs(DISPLAY_KEYS) do
            if parsed[key] == nil then
                local patt = "['\"]?" .. key .. "['\"]?%s*=%s*"
                local i = text:find(key, 1, true)
                while i do
                    local prefix = text:sub(math.max(1, i - 1), i - 1)
                    if (prefix == "" or prefix:match("[%s,{]")) and text:match("^" .. patt, i) then
                        local after = text:match("^" .. patt, i)
                        local value = parseString(text, i + #after)
                        if value then
                            parsed[key] = value
                            break
                        end
                    end
                    i = text:find(key, i + 1, true)
                end
            end
        end
    end
    if parsed.name == nil and parsed.fullname == nil and parsed.title == nil
        and parsed.version == nil and parsed.description == nil then
        return nil, "no_meta"
    end
    return parsed
end

---@param locale table|nil
---@return string|nil, string|nil
local function localeTitleDesc(locale)
    if type(locale) ~= "table" then return nil, nil end
    local title = locale.title or locale.fullname or locale.name or locale.title_zh
    local desc = locale.description or locale.description_zh
    return title, desc
end

--- 已有中文标题优先；否则用源文字面量。不臆造翻译。
---@param meta table|nil
---@param fallback string|nil
---@return string|nil
function Meta.displayTitle(meta, fallback)
    if type(meta) ~= "table" then return fallback end
    local locales = { meta.zh, meta.zh_CN, meta.zh_cn, meta.zh_TW, meta.zh_tw }
    if type(meta.l10n) == "table" then
        locales[#locales + 1] = meta.l10n.zh or meta.l10n.zh_CN or meta.l10n.zh_TW
    end
    for _idx, locale in ipairs(locales) do
        local title = localeTitleDesc(locale)
        if type(title) == "string" and title ~= "" then return title end
    end
    for _idx, value in ipairs({ meta.title_zh, meta.fullname_zh, meta.name_zh, meta.title, meta.fullname, meta.name }) do
        if type(value) == "string" and value ~= "" and isCjk(value) then return value end
    end
    return meta.title or meta.fullname or meta.name or fallback
end

---@param meta table|nil
---@param fallback string|nil
---@return string|nil
function Meta.displayDescription(meta, fallback)
    if type(meta) ~= "table" then return fallback end
    local locales = { meta.zh, meta.zh_CN, meta.zh_cn, meta.zh_TW, meta.zh_tw }
    if type(meta.l10n) == "table" then
        locales[#locales + 1] = meta.l10n.zh or meta.l10n.zh_CN or meta.l10n.zh_TW
    end
    for _idx, locale in ipairs(locales) do
        local _title, desc = localeTitleDesc(locale)
        if type(desc) == "string" and desc ~= "" then return desc end
    end
    for _idx, value in ipairs({ meta.description_zh, meta.description }) do
        if type(value) == "string" and value ~= "" and isCjk(value) then return value end
    end
    return meta.description or fallback
end

Meta.isCjk = isCjk

return Meta
