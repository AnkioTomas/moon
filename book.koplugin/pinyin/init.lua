--[[--
中文键盘入口 + 拼音候选词增强。

开关只存 Book 通用设置（沿用旧键 pinyin_enabled，兼容已有配置）。
开启 = 把 zh_CN（以及 en，用于一键切回）补进 KOReader 键盘布局列表，
用户点键盘上的 🌐 键在中英之间循环切换。

候选增强：开启时后台确保词库（pinyin/download）在，然后包装
generic_ime 原型的 getCandiFromMap —— 原生单字候选保留在后，
词库整词按词频插在前。词库缺失/查询失败时包装层直接透传，
不打扰原生候选。

@module koplugin.book.pinyin
--]]

local Settings = require("utils.settings")
require("l10n").apply()

local Pinyin = {}

local _hooked = false

--- 当前是否启用中文键盘入口。
---@return boolean
function Pinyin.isEnabled()
    return Settings.get().pinyin_enabled == true
end

--- 把 en / zh_CN 补进 KOReader 键盘布局列表（保留用户已有布局与顺序）。
---@return nil
local function ensureLayouts()
    local layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    local have = {}
    for _, l in ipairs(layouts) do
        have[l] = true
    end
    if not have.en then
        table.insert(layouts, "en")
    end
    if not have.zh_CN then
        table.insert(layouts, "zh_CN")
    end
    G_reader_settings:saveSetting("keyboard_layouts", layouts)
end

--- 安装 IME 候选增强 hook（幂等）。词库不可用时透传，无负担。
--- zh_CN 实例特征：switch_char="→" 且 switch_char_prev="←"（见 zh_CN_keyboard.lua），
--- 其它共用 generic_ime 原型的布局（ja/vi/ko_KR…）不匹配、零影响。
---
--- 输入码是逐键连写（"nihao"），Dict.lookup 内部切成 "ni hao" 前缀匹配词库：
--- 整词（你好）+ 单字（你）按词频混排，插到原生单字候选之前。
local function ensureHook()
    if _hooked then
        return
    end
    local ok, IME = pcall(require, "ui/data/keyboardlayouts/generic_ime")
    if not ok or type(IME) ~= "table" or type(IME.getCandiFromMap) ~= "function" then
        return
    end
    _hooked = true
    local orig = IME.getCandiFromMap
    IME.getCandiFromMap = function(self, code)
        local native = orig(self, code)
        if self.switch_char ~= "→" or self.switch_char_prev ~= "←" then
            return native
        end
        if type(code) ~= "string" or not code:match("^[a-z]+$") then
            return native
        end
        local Dict = require("pinyin.dictionary")
        if not Dict.isAvailable() then
            return native
        end
        local words = Dict.lookup(code)
        if #words == 0 then
            return native
        end
        local seen, out = {}, {}
        for _, w in ipairs(words) do
            if not seen[w] then
                seen[w] = true
                out[#out + 1] = w
            end
        end
        for _, w in ipairs(native or {}) do
            if not seen[w] then
                seen[w] = true
                out[#out + 1] = w
            end
        end
        return out
    end
end

--- 后台确保词库在（开启时静默拉取；失败不打扰，下次输入再试）。
local function ensureDict()
    require("pinyin.download").ensure(function(ok, err)
        if not ok then
            require("logger").warn("book.pinyin dict ensure failed:", err)
        end
    end)
end

--- 写入开关；开启时补键盘布局 + 后台备词库（关闭不动布局列表——可能还有别人在用）。
---@param value boolean
---@return boolean
function Pinyin.setEnabled(value)
    local settings = Settings.get()
    settings.pinyin_enabled = value == true
    Settings.save(settings)
    if settings.pinyin_enabled then
        ensureLayouts()
        ensureDict()
    end
    return settings.pinyin_enabled
end

--- 插件启动：已开启则装 hook（词库已在则即时生效，没在等后台下载）。
function Pinyin.bootstrap()
    if not Pinyin.isEnabled() then
        return
    end
    ensureHook()
end

--- 词库状态（设置页显示）：未下载 / 下载中 / N 条（tag）。
---@return string
function Pinyin.dictStatus()
    local _ = require("gettext")
    if require("pinyin.download").downloading() then
        return _("下载中…")
    end
    local Dict = require("pinyin.dictionary")
    if not Dict.isAvailable() then
        return _("未下载")
    end
    local entries = Dict.entries() or "?"
    local tag = Dict.sourceTag() or Settings.get().pinyin_dict_source or "?"
    return string.format("%s · %s", entries, tag)
end

--- 手动下载 / 更新词库（设置页点击）。
---@param cb fun(ok: boolean, err: any)|nil
function Pinyin.downloadDict(cb)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        require("pinyin.download").ensure(cb, true) -- force：按最新 manifest 重拉
    end)
end

return Pinyin
