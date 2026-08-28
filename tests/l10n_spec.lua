--[[--
l10n 目录一致性：en 与 zh_TW 键集必须双向一致，所有值是非空字符串。
键漂移（漏翻）时失败消息列出差异键。

@module tests.l10n_spec
--]]

local Assert = require("support.assert")

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
    --- 目录经 dofile 后是真字符，不还原就会把 `_("桌面打开失败:\n")` 误报成缺键。
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

    --- 键还原成源码里的字面写法，用于反查
    ---@param s string
    ---@return string
    local function escape(s)
        return (s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r"))
    end

    local root = require("support.config").root()
    local pipe = assert(io.popen(string.format(
        "find %s/book.koplugin -name '*.lua' -not -path '*/l10n/*' -not -path '*/types/*'",
        root)))
    local sources = {}
    for path in pipe:lines() do
        local fh = assert(io.open(path, "rb"))
        sources[#sources + 1] = fh:read("*a")
        fh:close()
    end
    pipe:close()

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

    -- 反向：目录里不许留源码用不到的键。
    -- 文案改一版就留一条旧键，攒到过 207 条（占目录 24%），全是维护噪音。
    local stale = {}
    for key in pairs(en) do
        local needle = escape(key)
        local found = false
        for _, src in ipairs(sources) do
            if src:find(needle, 1, true) then found = true break end
        end
        if not found then stale[#stale + 1] = key end
    end
    table.sort(stale)
    Assert.len(stale, 0, "l10n 目录残留源码里已不用的键: " .. table.concat(stale, " | "))
end
