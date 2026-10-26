--[[--
中文键盘入口与输入法选择。

@module koplugin.book.features.ime
--]]

local Settings = require("utils.settings")
local Registry = require("features.ime.registry")
local _ = require("gettext")
require("l10n").apply()

local IME = {}
local PREVIOUS_LAYOUTS_KEY = "book_pinyin_previous_keyboard_layouts"

--- 当前是否启用中文键盘入口。
function IME.isEnabled()
    return Settings.get("features.ime").pinyin_enabled
end

---@return string
function IME.layout()
    return Registry.current().id
end

---@param id string
---@return boolean
function IME.setLayout(id)
    local selected = Registry.get(id)
    if selected.id ~= id then return false end
    local settings = Settings.get("features.ime")
    settings.ime_layout = id
    Settings.save("features.ime", settings)
    return true
end

function IME.layouts()
    return Registry.list()
end

--- 浅拷贝布局列表：快照要跟 G_reader_settings 里的表脱钩，否则后续改写会连快照一起改。
---@param layouts string[]|nil
---@return string[]
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
        ---@cast layouts string[]
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
function IME.setEnabled(value)
    if value == true and not Registry.isAvailable(Registry.current()) then
        return false
    end
    local settings = Settings.get("features.ime")
    settings.pinyin_enabled = value == true
    Settings.save("features.ime", settings)
    if settings.pinyin_enabled then
        ensureLayouts()
        require("features.ime.candidate_bar").install({ enabled = IME.isEnabled })
    else
        restoreLayouts()
    end
    return settings.pinyin_enabled
end

--- 插件启动时恢复已启用的候选栏钩子。
function IME.onCreate()
    require("features.ime.hide_key").onCreate()
    if not IME.isEnabled() then
        return
    end
    -- 布局列表可能被 KOReader 设置重置，开关仍开着却没有 zh_CN 可切
    local layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    ---@cast layouts string[]
    local has_zh = false
    for _idx, layout in ipairs(layouts) do
        has_zh = has_zh or layout == "zh_CN"
    end
    if not has_zh then
        ensureLayouts()
    end
    require("features.ime.candidate_bar").install({ enabled = IME.isEnabled })
end

--- 设置页词库状态：未下载、下载中、不可用或词条数与构建版本。
function IME.dictStatus()
    if require("features.ime.download").downloading() then
        return _("下载中…")
    end
    local method = Registry.current()
    if not Registry.isAvailable(method) then
        if Registry.fileExists(method) then
            return _("词库文件存在但不可用")
        end
        return _("未下载")
    end
    local entries = Registry.entries(method) or "?"
    local built_at = Registry.builtAt(method)
        or Settings.get("features.ime").ime_dict_built_at[method.dictionary] or "?"
    return string.format("%s · %s", entries, built_at)
end

--- 手动下载或更新词库；离线时立即失败，由用户恢复网络后手动重试。
---@param cb fun(ok: boolean, err: any)|nil
---@param on_progress fun(stage: string, done: number|nil, total: number|nil, idx: number|nil, count: number|nil)|nil
function IME.downloadDict(cb, on_progress)
    cb = cb or function() end
    if not require("ui/network/manager"):isConnected() then
        cb(false, _("网络不可用，请先连接 Wi-Fi"))
        return
    end
    require("features.ime.download").ensure(Registry.current().dictionary, cb, on_progress)
end

return IME
