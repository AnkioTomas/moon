--[[--
中文键盘入口 + 拼音候选栏。

开关只存 Book 通用设置（沿用旧键 pinyin_enabled，兼容已有配置）。
开启 = 把 zh_CN（以及 en，用于一键切回）补进 KOReader 键盘布局列表，
用户点键盘上的 🌐 键在中英之间循环切换。

候选栏（pinyin/candidate_bar）：zh_CN 布局下字母绕过原生 IME 行内提示，
词库整词/单字候选直接显示在键盘首行；词库缺失时全部透传，回退原生行为。

@module koplugin.book.pinyin
--]]

local Settings = require("utils.settings")
require("l10n").apply()

local Pinyin = {}

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

--- 写入开关；开启时补键盘布局 + 装候选栏（词库按用户确认后下载）。
---@param value boolean
---@return boolean
function Pinyin.setEnabled(value)
    if value == true and not require("pinyin.dictionary").isAvailable() then
        return false
    end
    local settings = Settings.get()
    settings.pinyin_enabled = value == true
    Settings.save(settings)
    if settings.pinyin_enabled then
        ensureLayouts()
        require("pinyin.candidate_bar").install({ enabled = Pinyin.isEnabled })
    end
    return settings.pinyin_enabled
end

--- 插件启动：已开启则装候选栏（词库已在即时生效，没在等后台下载后下次键盘激活）。
function Pinyin.bootstrap()
    if not Pinyin.isEnabled() then
        return
    end
    require("pinyin.candidate_bar").install({ enabled = Pinyin.isEnabled })
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
        if Dict.fileExists and Dict.fileExists() then
            return _("词库文件存在但不可用")
        end
        return _("未下载")
    end
    local entries = Dict.entries() or "?"
    local tag = Dict.sourceTag() or Settings.get().pinyin_dict_source or "?"
    return string.format("%s · %s", entries, tag)
end

--- 手动下载 / 更新词库（设置页点击）。
---@param cb fun(ok: boolean, err: any)|nil
---@param on_progress fun(stage: string, done: number|nil, total: number|nil, idx: number|nil, count: number|nil)|nil
function Pinyin.downloadDict(cb, on_progress)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        require("pinyin.download").ensure(cb, true, on_progress) -- force：按最新 manifest 重拉
    end)
end

return Pinyin
