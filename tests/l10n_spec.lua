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

-- 双向键集一致
do
    local only_en = missingKeys(en, zh_tw)
    local only_zh = missingKeys(zh_tw, en)
    Assert.len(only_en, 0, "zh_TW 缺少 en 的键: " .. table.concat(only_en, ", "))
    Assert.len(only_zh, 0, "en 缺少 zh_TW 的键: " .. table.concat(only_zh, ", "))
end
