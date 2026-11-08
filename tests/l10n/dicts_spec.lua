--[[--
核心与书源词典：键集、占位符、源码覆盖与归属一致。
书源专属文案不得回流到核心词典，共享文案由核心提供。

@module tests.l10n.dicts_spec
--]]

local Assert = require("support.assert")

local root = require("support.config").root()

local function read(path)
    local fh = assert(io.open(path, "rb"))
    local text = fh:read("*a")
    fh:close()
    return text
end

-- require 后重复键已经被 Lua 覆盖，必须在加载目录前检查源文件。
local function assertNoDuplicateKeys(path)
    local fh = assert(io.open(path, "rb"))
    local seen = {}
    local line_no = 0
    for line in fh:lines() do
        line_no = line_no + 1
        local key = line:match('^%s*%["(.*)"%]%s*=')
        if key then
            Assert.is_nil(seen[key], string.format(
                "%s 重复键: %s（第 %d、%d 行）", path, key, seen[key] or 0, line_no))
            seen[key] = line_no
        end
    end
    fh:close()
end

local function unescape(s)
    return (s:gsub("\\(.)", function(ch)
        if ch == "n" then return "\n" end
        if ch == "t" then return "\t" end
        if ch == "r" then return "\r" end
        return ch
    end))
end

local owners = { l10n = { texts = {}, literals = {} } }
local meta_paths = assert(io.popen(string.format(
    "find %s/book.koplugin/source -name _meta.lua", root)))
for path in meta_paths:lines() do
    local id = assert(path:match("/source/([^/]+)/_meta%.lua$"))
    owners["source." .. id] = { texts = {}, literals = {} }
end
meta_paths:close()

local sources = assert(io.popen(string.format(
    "find %s/book.koplugin -name '*.lua' -not -path '*/l10n/*' -not -path '*/types/*'", root)))
for path in sources:lines() do
    local id = path:match("/source/([^/]+)/")
    local owner = id and owners["source." .. id] or owners.l10n
    local text = read(path)
    owner.texts[#owner.texts + 1] = text
    for literal in text:gmatch('"([^"\n]*)"') do owner.literals[unescape(literal)] = true end
    for literal in text:gmatch("'([^'\n]*)'") do owner.literals[unescape(literal)] = true end
    if owner ~= owners.l10n then
        Assert.is_nil(text:find('require("gettext")', 1, true), path .. " 仍使用全局书源翻译")
    end
end
sources:close()

local core = require("l10n.en")
local source_literals = {}
for name, owner in pairs(owners) do
    if name ~= "l10n" then
        for key in pairs(owner.literals) do source_literals[key] = true end
    end
end
for name, owner in pairs(owners) do
    local prefix = name == "l10n" and name or name .. ".l10n"
    local catalogs = {}
    for _idx, lang in ipairs({ "en", "zh_TW" }) do
        assertNoDuplicateKeys(root .. "/book.koplugin/" .. prefix:gsub("%.", "/") .. "/" .. lang .. ".lua")
        catalogs[lang] = require(prefix .. "." .. lang)
    end
    for lang, catalog in pairs(catalogs) do
        local other = catalogs[lang == "en" and "zh_TW" or "en"]
        for key, value in pairs(catalog) do
            local label = prefix .. "." .. lang .. ": " .. key
            Assert.eq(type(value), "string", label)
            Assert.is_true(value ~= "", label .. " 空译文")
            Assert.not_nil(other[key], label .. " 另一语言缺键")
            local expected, actual = {}, {}
            for n in key:gmatch("%%(%d)") do expected[n] = true end
            for n in value:gmatch("%%(%d)") do actual[n] = true end
            for n in pairs(expected) do Assert.is_true(actual[n] == true, label .. " 缺少 %" .. n) end
            for n in pairs(actual) do Assert.is_true(expected[n] == true, label .. " 多出 %" .. n) end
            if name ~= "l10n" then
                Assert.is_nil(core[key], label .. " 与核心重复")
            elseif source_literals[key] then
                Assert.is_true(owner.literals[key] == true, label .. " 书源专属文案不得放在核心")
            end
        end
    end
    local missing, seen = {}, {}
    for _idx, text in ipairs(owner.texts) do
        for literal in text:gmatch('_%(%s*"([^"]*)"') do
            local key = unescape(literal)
            if key ~= "" and not seen[key] then
                seen[key] = true
                if catalogs.en[key] == nil and core[key] == nil then missing[#missing + 1] = key end
            end
        end
    end
    table.sort(missing)
    Assert.len(missing, 0, prefix .. " 缺少源码文案: " .. table.concat(missing, " | "))
end
