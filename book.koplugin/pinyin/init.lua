--[[--
中文键盘入口 + 拼音候选栏。

@module koplugin.book.pinyin
--]]

local Settings = require("utils.settings")
local _ = require("gettext")
require("l10n").apply()

local Pinyin = {}
local PREVIOUS_LAYOUTS_KEY = "book_pinyin_previous_keyboard_layouts"

--- 当前是否启用中文键盘入口。
function Pinyin.isEnabled()
    return Settings.get().pinyin_enabled == true
end

local function copyLayouts(layouts)
    local copy = {}
    for i, layout in ipairs(layouts or {}) do
        copy[i] = layout
    end
    return copy
end

-- 中文输入启用时仅保留 en / zh_CN 布局，并保存启用前的布局列表。
local function ensureLayouts()
    if G_reader_settings:readSetting(PREVIOUS_LAYOUTS_KEY) == nil then
        local layouts = G_reader_settings:readSetting("keyboard_layouts", {})
        G_reader_settings:saveSetting(PREVIOUS_LAYOUTS_KEY, copyLayouts(layouts))
    end
    G_reader_settings:saveSetting("keyboard_layouts", { "en", "zh_CN" })
end

-- 关闭拼音时恢复启用前的布局；没有快照时保持现状。
local function restoreLayouts()
    local layouts = G_reader_settings:readSetting(PREVIOUS_LAYOUTS_KEY)
    if layouts == nil then
        return
    end
    G_reader_settings:saveSetting("keyboard_layouts", layouts)
    G_reader_settings:delSetting(PREVIOUS_LAYOUTS_KEY)
end

--- 写入开关；词库不可用时拒绝开启，避免留下无效键盘入口。
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
    else
        restoreLayouts()
    end
    return settings.pinyin_enabled
end

--- 插件启动时恢复已启用的候选栏钩子。
function Pinyin.bootstrap()
    if not Pinyin.isEnabled() then
        return
    end
    require("pinyin.candidate_bar").install({ enabled = Pinyin.isEnabled })
end

--- 设置页词库状态：未下载、下载中、不可用或词条数与构建版本。
function Pinyin.dictStatus()
    if require("pinyin.download").downloading() then
        return _("下载中…")
    end
    local Dict = require("pinyin.dictionary")
    if not Dict.isAvailable() then
        if Dict.fileExists() then
            return _("词库文件存在但不可用")
        end
        return _("未下载")
    end
    local entries = Dict.entries() or "?"
    local built_at = Dict.builtAt() or Settings.get().pinyin_dict_built_at or "?"
    return string.format("%s · %s", entries, built_at)
end

--- 手动下载或更新词库；网络不可用时由 NetworkMgr 延后执行。
---@param cb fun(ok: boolean, err: any)|nil
---@param on_progress fun(stage: string, done: number|nil, total: number|nil, idx: number|nil, count: number|nil)|nil
function Pinyin.downloadDict(cb, on_progress)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        require("pinyin.download").ensure(cb, on_progress)
    end)
end

return Pinyin
