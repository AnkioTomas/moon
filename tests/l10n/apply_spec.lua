--[[--
l10n.apply() 的目录回落规则：.utf8 后缀剥离、C/en→{en}、zh_TW/zh_HK→{zh_TW}、
zh→空目录不合并、其它语言 lang→base→en 逐级回落；同语言重复 apply 幂等。

l10n 模块在 require 时就 apply 一次且包级 applied_for 有状态，
因此每个用例清 package.loaded["l10n"] 再重 require。

@module tests.l10n.apply_spec
--]]

local Assert = require("support.assert")

local GetText = require("gettext")

local EN_KEY = "月读" -- en: "月读" / zh_TW: "月讀"
local EN_ONLY_KEY = "下载失败" -- 第二个代表键（msgid 是简体中文）

-- 取两个真实代表键，避免硬编码随目录更新而失效
local en_catalog = require("l10n.en")
local zh_catalog = require("l10n.zh_TW")
Assert.eq(en_catalog[EN_KEY], "月读")
Assert.eq(zh_catalog[EN_KEY], "月讀")
EN_ONLY_KEY = "下载失败"
Assert.not_nil(en_catalog[EN_ONLY_KEY])

local function clearTranslation()
    for k in pairs(GetText.translation) do
        GetText.translation[k] = nil
    end
end

--- 以指定语言重新加载 l10n 模块（require 时自动 apply 一次）
---@return table 模块
local function applyFor(lang)
    GetText.current_lang = lang
    clearTranslation()
    package.loaded["l10n"] = nil
    return require("l10n")
end

local function translationCount()
    local n = 0
    for _ in pairs(GetText.translation) do
        n = n + 1
    end
    return n
end

-- C → en
do
    applyFor("C")
    Assert.eq(GetText.translation[EN_KEY], "月读")
    Assert.eq(GetText.translation[EN_ONLY_KEY], en_catalog[EN_ONLY_KEY])
end

-- en_US.utf8：剥离 .utf8 后缀后命中 ^en
do
    applyFor("en_US.utf8")
    Assert.eq(GetText.translation[EN_KEY], "月读")
end

-- en_GB.UTF-8：剥离 .UTF-8 后缀
do
    applyFor("en_GB.UTF-8")
    Assert.eq(GetText.translation[EN_KEY], "月读")
end

-- zh_TW / zh_HK → zh_TW 目录
do
    applyFor("zh_TW")
    Assert.eq(GetText.translation[EN_KEY], "月讀")

    applyFor("zh_HK")
    Assert.eq(GetText.translation[EN_KEY], "月讀")
end

-- zh / zh_CN：源字符串即简体中文，空候选不合并任何翻译
do
    applyFor("zh_CN")
    Assert.eq(translationCount(), 0, "zh_CN 不应合并任何翻译")

    applyFor("zh")
    Assert.eq(translationCount(), 0, "zh 不应合并任何翻译")
end

-- 其它语言：lang → base → en 回落（fr_FR/fr 目录不存在，最终落到 en）
do
    applyFor("fr")
    Assert.eq(GetText.translation[EN_KEY], "月读")

    applyFor("fr_FR")
    Assert.eq(GetText.translation[EN_KEY], "月读")
end

-- 同语言重复 apply 幂等：applied_for 命中后不再触碰 translation
do
    local M = applyFor("C")
    Assert.eq(GetText.translation[EN_KEY], "月读")
    -- 人为破坏一条翻译；若再次合并会被还原，幂等则保持破坏
    GetText.translation[EN_KEY] = "sentinel"
    M.apply()
    Assert.eq(GetText.translation[EN_KEY], "sentinel", "同语言重复 apply 不应重新合并")
end
