--[[--
l10n 目录一致性：en 与 zh_TW 键集必须双向一致，所有值是非空字符串。
键漂移（漏翻）时失败消息列出差异键。

@module tests.l10n_spec
--]]

local Assert = require("support.assert")

local root = require("support.config").root()

-- require 后重复键已经被 Lua 覆盖，必须在加载目录前检查源文件。
local function assertNoDuplicateKeys(lang)
    local path = string.format("%s/book.koplugin/l10n/%s.lua", root, lang)
    local fh = assert(io.open(path, "rb"))
    local seen = {}
    local line_no = 0
    for line in fh:lines() do
        line_no = line_no + 1
        local key = line:match('^%s*%["(.*)"%]%s*=')
        if key then
            Assert.is_nil(seen[key], string.format(
                "%s 重复键: %s（第 %d、%d 行）", lang, key, seen[key] or 0, line_no))
            seen[key] = line_no
        end
    end
    fh:close()
end

assertNoDuplicateKeys("en")
assertNoDuplicateKeys("zh_TW")

local en = require("l10n.en")
local zh_tw = require("l10n.zh_TW")

--- 收集 keys 中不在 other 里的键（排序后便于阅读失败消息）
local function missingKeys(keys_of, other)
    local out = {}
    for k in pairs(keys_of) do
        if other[k] == nil then
            out[#out + 1] = k
        end
    end
    table.sort(out)
    return out
end

-- 值必须是非空字符串
for lang, catalog in pairs({ en = en, zh_TW = zh_tw }) do
    for k, v in pairs(catalog) do
        Assert.eq(type(v), "string", lang .. " 的值必须是字符串: " .. k)
        Assert.is_true(v ~= "", lang .. " 的值不能为空: " .. k)
    end
end

-- 占位符集必须与源字符串一致：译文漏掉 %1 就是运行时少一段信息（错误原因、书名等），
-- 多出 %2 则会显示成字面量。
for lang, catalog in pairs({ en = en, zh_TW = zh_tw }) do
    for key, value in pairs(catalog) do
        local expected = {}
        for n in key:gmatch("%%(%d)") do expected[n] = true end
        local actual = {}
        for n in value:gmatch("%%(%d)") do actual[n] = true end
        for n in pairs(expected) do
            Assert.is_true(actual[n] == true,
                lang .. " 译文缺少占位符 %" .. n .. ": " .. key)
        end
        for n in pairs(actual) do
            Assert.is_true(expected[n] == true,
                lang .. " 译文多出占位符 %" .. n .. ": " .. key)
        end
    end
end

-- 双向键集一致
do
    local only_en = missingKeys(en, zh_tw)
    local only_zh = missingKeys(zh_tw, en)
    Assert.len(only_en, 0, "zh_TW 缺少 en 的键: " .. table.concat(only_en, ", "))
    Assert.len(only_zh, 0, "en 缺少 zh_TW 的键: " .. table.concat(only_zh, ", "))
end

-- 源码 msgid 全覆盖。
--
-- 只做双向一致查不出「两边一起缺」——那正是历史上 107 个键的状态：目录自洽，
-- 但源码里的文案根本没进目录，切语言后原样显示简体。
do
    --- 源文件是文本，捕获到的是字面转义序列（`\n` 是反斜杠加 n）；
    --- 目录经 dofile 后是真字符，不还原就会把含 `\n` 的 msgid 误报成缺键。
    ---@param s string
    ---@return string
    local function unescape(s)
        return (s:gsub("\\(.)", function(ch)
            if ch == "n" then return "\n" end
            if ch == "t" then return "\t" end
            if ch == "r" then return "\r" end
            return ch
        end))
    end

    --- 读若干目录树下的全部源码文本，跳过 l10n 目录（目录自己）与 types 桩。
    ---@param dirs string[]
    ---@return string[]
    local function sourceTexts(dirs)
        local pipe = assert(io.popen(string.format(
            "find %s -name '*.lua' -not -path '*/l10n/*' -not -path '*/types/*'",
            table.concat(dirs, " "))))
        local out = {}
        for path in pipe:lines() do
            local fh = assert(io.open(path, "rb"))
            out[#out + 1] = fh:read("*a")
            fh:close()
        end
        pipe:close()
        return out
    end

    local sources = sourceTexts({ root .. "/book.koplugin" })
    local extension_sources = sourceTexts({ root .. "/extensions" })
    -- 扩展（extensions/）文案正按票逐条纳入目录：正向「源码 msgid 全覆盖」仍只按核心插件查
    -- （扩展存量文案还没翻完），但反向「残留键」必须一并收扩展源码——否则刚纳入的扩展键
    -- 会被误判成源码里已不用。
    local literal_sources = {}
    for _idx, src in ipairs(sources) do literal_sources[#literal_sources + 1] = src end
    for _idx, src in ipairs(extension_sources) do literal_sources[#literal_sources + 1] = src end

    local missing, seen = {}, {}
    for _, src in ipairs(sources) do
        for literal in src:gmatch('_%(%s*"([^"]*)"') do
            local msgid = unescape(literal)
            if msgid ~= "" and not seen[msgid] then
                seen[msgid] = true
                if en[msgid] == nil then
                    missing[#missing + 1] = msgid
                end
            end
        end
    end
    table.sort(missing)
    Assert.len(missing, 0, "l10n 目录缺少源码里的文案: " .. table.concat(missing, " | "))

    -- Kavita 扩展的文案已全部纳入目录（09 验收补齐）；只按这个扩展查正向覆盖，
    -- 不要求其它扩展一次翻完，避免把存量文案变成红灯。
    local kavita_sources = sourceTexts({ root .. "/extensions/moonsource-kavita.koplugin" })
    local kavita_missing, kavita_seen = {}, {}
    for _, src in ipairs(kavita_sources) do
        for literal in src:gmatch('_%(%s*"([^"]*)"') do
            local msgid = unescape(literal)
            if msgid ~= "" and not kavita_seen[msgid] then
                kavita_seen[msgid] = true
                if en[msgid] == nil then kavita_missing[#kavita_missing + 1] = msgid end
            end
        end
    end
    table.sort(kavita_missing)
    Assert.len(kavita_missing, 0,
        "Kavita 扩展缺少 l10n 文案: " .. table.concat(kavita_missing, " | "))

    -- 反向：目录键必须作为完整字符串存在于源码。不能用裸 substring 搜索，
    -- 否则「账号」会被「微信读书账号」冒充使用，注释也会掩盖废弃键。
    local source_literals = {}
    for _, src in ipairs(literal_sources) do
        for literal in src:gmatch('"([^"\n]*)"') do
            source_literals[unescape(literal)] = true
        end
        for literal in src:gmatch("'([^'\n]*)'") do
            source_literals[unescape(literal)] = true
        end
    end
    -- 拿一条只存在于扩展源码里的键钉住「扩展也是目录键的合法来源」。
    Assert.is_true(source_literals["获取增强版"] == true,
        "扩展源码没进残留键判定：extensions/ 下的文案会被误报为残留键")

    local stale = {}
    for key in pairs(en) do
        if not source_literals[key] then stale[#stale + 1] = key end
    end
    table.sort(stale)
    Assert.len(stale, 0, "l10n 目录残留源码里已不用的键: " .. table.concat(stale, " | "))
end
