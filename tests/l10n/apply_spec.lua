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
for _, key in ipairs({
    "状态", "已读", "未读", "正在打开",
    "更新阅读状态失败", "彻底删除《%1》？\n\n会清理：本地文件与缓存、书架条目、阅读进度、划线与笔记、统计\n有云端时下次同步也会从远端删除，无法从「软删除」筛选恢复。",
    "读到 99% 自动标记已读",
    "未分类", "无系列",
}) do
    Assert.not_nil(en_catalog[key], "英文目录缺少: " .. key)
    Assert.not_nil(zh_catalog[key], "繁中目录缺少: " .. key)
end

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
    for _key in pairs(GetText.translation) do
        n = n + 1
    end
    return n
end

-- 书源词典按自身语言回落，不进入核心目录或全局 gettext。
do
    local M = applyFor("en_US")
    local key = "起点分类响应无效"
    local name, catalog = M.catalog("en_US", "source.qidian")
    Assert.eq(name, "en")
    Assert.eq(catalog[key], "Invalid Qidian category response.")
    Assert.is_nil(en_catalog[key])
    Assert.is_nil(GetText.translation[key])
    local translate = M.get("source.qidian")
    Assert.eq(translate(key), catalog[key])
    Assert.is_nil(GetText.translation[key], "书源翻译不得写入全局 gettext")
    Assert.eq(translate("下载失败"), GetText("下载失败"), "共享文案复用 gettext")
    Assert.eq(translate("未知书源文案"), "未知书源文案")
    Assert.eq(M.get("source.wechat")(key), key, "其它书源不能看到起点译文")

    M = applyFor("zh_HK")
    local _tw_name, tw = M.catalog("zh_HK", "source.qidian")
    Assert.eq(M.get("source.qidian")(key), tw[key])
    Assert.is_nil(GetText.translation[key])

    M = applyFor("fr_FR")
    Assert.eq(M.get("source.qidian")(key), catalog[key])
    M = applyFor("zh_CN.UTF-8")
    Assert.eq(M.get("source.qidian")(key), key)
    Assert.eq(translationCount(), 0)
end

-- 书源元信息在独立 require 时也使用自己的词典。
do
    applyFor("en")
    package.loaded["source.qidian._meta"] = nil
    local meta = require("source.qidian._meta")
    Assert.eq(meta.description, "Qidian shelf and online reading")
    Assert.is_nil(GetText.translation["起点中文网书架与在线阅读"])
end

-- 缺失的语言目录可回落，损坏的目录必须暴露错误。
do
    local M = applyFor("en")
    package.preload["source.broken.l10n.en"] = function() error("broken catalog") end
    Assert.errors(function() M.get("source.broken") end, "broken catalog")
    package.preload["source.invalid.l10n.en"] = function() return "not a catalog" end
    Assert.errors(function() M.get("source.invalid") end, "must return a translation table")
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
