--[[--
中文键盘入口与输入方式协调。

`input_mode`（`system` / `builtin`）决定文字输入走哪条通路；nil 表示按平台默认。
旧 `features.system_ime.enabled` 只在首次迁移时读取：显式 `false` 写成
`input_mode = "builtin"`，其余走平台默认；之后旧键不参与计算。

模式互斥与后端路由都在这里：system 模式停用候选栏、恢复拼音前布局，并把
`VirtualKeyboard.showKeyboard/hideKeyboard` 交给平台后端；number / password /
readonly 字段始终走内置键盘。后端模块缺失时按不可用处理，降级到原生 VK。

@module koplugin.book.features.ime
--]]

local Settings = require("utils.settings")
local Registry = require("features.ime.registry")
local Platform = require("features.ime.platform")
local Backend = require("features.ime.backend")
local Field = require("features.ime.field")
local _ = require("gettext")
require("l10n").apply()

local IME = {}
local PREVIOUS_LAYOUTS_KEY = "book_pinyin_previous_keyboard_layouts"
local MODE_KEY = "input_mode"
local MODES = { system = true, builtin = true }

---@type table<string, table> 后端模块名 → 已装载后端（平台在进程内不变）
local backends = {}

-- ── 输入方式 ─────────────────────────────────────────

---@return table
local function imeSettings()
    return Settings.get("features.ime")
end

--- 旧开关只用于迁移：显式 false 返回 true，其余返回 nil（走平台默认）。
---@return boolean|nil
local function legacyBuiltin()
    local ok, legacy = pcall(Settings.get, "features.system_ime")
    if not ok or type(legacy) ~= "table" then
        return nil
    end
    return legacy.enabled == false or nil
end

---@return "system"|"builtin"
local function platformDefault()
    return Platform.defaultMode(Platform.current())
end

--- 首次迁移的解析值：旧开关显式关闭 → builtin；墨水屏强制 builtin；其余按平台默认。
---@return "system"|"builtin"
local function resolveMode()
    if legacyBuiltin() then return "builtin" end
    if Platform.isEinkCurrent() then return "builtin" end
    return platformDefault()
end

--- 读存储值；nil / 无效值只在第一次解析并写回 `input_mode`，之后旧键不再参与。
---@return "system"|"builtin"
local function storedMode()
    local settings = imeSettings()
    local stored = settings[MODE_KEY]
    if MODES[stored] then
        return stored
    end
    local resolved = resolveMode()
    settings[MODE_KEY] = resolved
    Settings.save("features.ime", settings)
    return resolved
end

--- 有效输入方式：墨水屏无条件 builtin，否则用已迁移的显式选择。
---@return "system"|"builtin"
function IME.inputMode()
    local stored = storedMode()
    if Platform.isEinkCurrent() then
        return "builtin"
    end
    return stored
end

--- 写用户选择并立即应用；墨水屏仍会被 inputMode() 强制为 builtin。
---@param mode "system"|"builtin"
---@return boolean
function IME.setInputMode(mode)
    if not MODES[mode] then
        return false
    end
    local settings = imeSettings()
    settings[MODE_KEY] = mode
    Settings.save("features.ime", settings)
    IME.applyMode{ tighten = true }
    return true
end

--- 内置候选栏是否应该工作：拼音开关 + 当前有效模式为 builtin。
---@return boolean
function IME.builtinEnabled()
    return IME.isEnabled() and IME.inputMode() == "builtin"
end

--- 当前平台对应的输入后端；模块缺失 / 墨水屏时返回不可用后端。
---@return table
function IME.backend()
    local name = Platform.backend(Platform.current())
    if not name then
        return Backend.unavailable()
    end
    local backend = backends[name]
    if not backend then
        backend = Backend.load(name)
        backends[name] = backend
    end
    return backend
end

-- ── 内置键盘开关 ─────────────────────────────────────

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

--- 恢复启用拼音前的布局；keep_snapshot 为真时保留快照供下次切回 builtin。
---@param keep_snapshot boolean|nil
local function restoreLayouts(keep_snapshot)
    local layouts = G_reader_settings:readSetting(PREVIOUS_LAYOUTS_KEY)
    if layouts == nil then
        return
    end
    G_reader_settings:saveSetting("keyboard_layouts", copyLayouts(layouts))
    if not keep_snapshot then
        G_reader_settings:delSetting(PREVIOUS_LAYOUTS_KEY)
    end
end

--- 布局是否需要收紧：当前列表还没有 zh_CN（拼音候选栏依赖它）。
--- 显式切换模式 / 打开拼音时走 opts.tighten，无条件收紧。
---@return boolean
local function layoutsNeedTightening()
    local layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    ---@cast layouts string[]
    for _idx, layout in ipairs(layouts) do
        if layout == "zh_CN" then return false end
    end
    return true
end

--- 已加载的候选栏模块；没加载过就不为一个 reset 把整套候选栏拉起来。
---@return table|nil
local function loadedBar()
    local bar = package.loaded["features.ime.candidate_bar"]
    if type(bar) == "table" then
        return bar
    end
    return nil
end

--- 按当前有效模式应用互斥：system 停用候选栏并恢复布局，builtin 重新收紧并激活。
---@param opts { tighten: boolean|nil }|nil tighten 为真时无条件收紧布局（显式切换 / 打开拼音）
function IME.applyMode(opts)
    opts = opts or {}
    if IME.inputMode() == "system" then
        local bar = loadedBar()
        if bar and bar.reset then bar.reset() end
        -- 保留快照：退出系统模式时还要按 pinyin_enabled 重新收紧。
        restoreLayouts(true)
        return
    end
    if not IME.isEnabled() then
        local bar = loadedBar()
        if bar and bar.reset then bar.reset() end
        return
    end
    if opts.tighten or layoutsNeedTightening() then
        ensureLayouts()
    end
    local Bar = require("features.ime.candidate_bar")
    Bar.install{ enabled = IME.builtinEnabled }
    if Bar.activate then Bar.activate() end
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
        IME.applyMode{ tighten = true }
    else
        local bar = loadedBar()
        if bar and bar.reset then bar.reset() end
        restoreLayouts()
    end
    return settings.pinyin_enabled
end

-- ── VirtualKeyboard 路由 ─────────────────────────────

local routing_hooked = false
local orig_show, orig_hide
local shown_backend

--- 本次 showKeyboard 是否交给系统后端。
---@param vk table|nil
---@return boolean
local function useSystemBackend(vk)
    if IME.inputMode() ~= "system" then return false end
    if Field.usesBuiltin(vk and vk.inputbox) then return false end
    return IME.backend().available()
end

--- 包装 VirtualKeyboard.showKeyboard：system 模式交给后端且不显示 VK，
--- 其余情况（builtin / 字段例外 / 后端不可用）走原生 VK。
local function wrappedShowKeyboard(self, ...)
    local inputbox = self and self.inputbox
    -- 只读字段本来就没有键盘：两个后端都不弹；顺手收起之前残留的 VK。
    if Field.isReadonly(inputbox) then
        shown_backend = nil
        if type(self.isVisible) == "function" and self:isVisible() then
            pcall(orig_hide, self)
        end
        return
    end
    if useSystemBackend(self) then
        local backend = IME.backend()
        -- 从 builtin 切过来时旧 VK 可能还开着：先收掉，保证系统模式下不残留。
        if type(self.isVisible) == "function" and self:isVisible() then
            pcall(orig_hide, self)
        end
        local ok, shown = pcall(backend.show, self)
        if ok and shown ~= false then
            shown_backend = backend
            return
        end
    end
    shown_backend = nil
    return orig_show(self, ...)
end

--- 包装 VirtualKeyboard.hideKeyboard：先收系统键盘，再按需收原生 VK。
local function wrappedHideKeyboard(self, ...)
    local backend = shown_backend
    shown_backend = nil
    if backend then
        pcall(backend.hide, self)
    end
    return orig_hide(self, ...)
end

--- 安装 VirtualKeyboard 类级路由；重复调用不重复包装。
function IME.installRouting()
    if routing_hooked then return end
    local ok, VK = pcall(require, "ui/widget/virtualkeyboard")
    if not ok or type(VK) ~= "table" or type(VK.showKeyboard) ~= "function" then
        return
    end
    orig_show, orig_hide = VK.showKeyboard, VK.hideKeyboard
    VK.showKeyboard = wrappedShowKeyboard
    if type(orig_hide) == "function" then
        VK.hideKeyboard = wrappedHideKeyboard
    end
    routing_hooked = true
end

--- 插件启动时恢复钩子并按当前模式应用互斥。
function IME.onCreate()
    require("features.ime.hide_key").onCreate()
    IME.installRouting()
    IME.applyMode()
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
---@return CancelHandle|nil 离线时已经回调失败，没有在途请求
function IME.downloadDict(cb, on_progress)
    cb = cb or function() end
    if not require("ui/network/manager"):isConnected() then
        cb(false, _("网络不可用，请先连接 Wi-Fi"))
        return
    end
    return require("features.ime.download").ensure(Registry.current().dictionary, cb, on_progress)
end

-- 简繁转换版的目录；加载器 require 本模块时登记一次。
local Ext = require("utils.extension")
for _idx, dir in ipairs(require("features.ime.convert").DIRS) do
    Ext.add("note.derived_dirs", dir)
end

-- 主题输入框切焦点 / 关窗时丢弃系统输入法未提交的组合串；只在 system 模式生效。
Ext.add("modal.text_input_reset", function()
    if IME.inputMode() ~= "system" then return end
    local backend = IME.backend()
    if backend.reset then backend.reset() end
end)

return IME
