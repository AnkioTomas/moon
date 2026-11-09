--[[--
中文输入法设置。唯一的「输入法」入口：输入方式、按模式显示的系统 / 内置行。

@module koplugin.book.features.ime.setting
--]]

local Platform = require("features.ime.platform")
local _ = require("gettext")
local T = require("ffi/util").template

local RELEASES_URL = "https://github.com/AnkioTomas/moon/releases"

---@param desktop BookDesktop
---@param enable_after boolean|nil
local function download(desktop, enable_after)
    local IME = require("features.ime")
    local Toast = require("ui.themes.widgets.toast")
    require("workers.ui.task_dialog").start{
        key = "ime",
        kind = "download",
        title = _("输入法词库"),
        cancellable = true,
        run = function(report, done)
            return IME.downloadDict(function(ok, err)
                done({ ok = ok, err = err })
            end, function(stage, done_bytes, total)
                if stage == "part" then
                    report(nil, done_bytes, total)
                elseif stage == "assemble" then
                    report(_("拼接校验词库…"), done_bytes, total)
                end
            end)
        end,
        on_done = function(result)
            Toast:new{
                text = result.ok and _("输入法词库已就绪")
                    or T(_("下载失败: %1"), tostring(result.err or _("未知错误"))),
                timeout = 2,
            }:show()
            if result.ok and enable_after then IME.setEnabled(true) end
            if desktop.closed then return end
            desktop:updateView()
        end,
    }
end

---@param desktop BookDesktop
---@param enable_after boolean|nil
local function confirmDownload(desktop, enable_after)
    require("ui.themes.widgets.confirm"):new{
        text = _("新词库可能需要新版插件支持。是否继续下载？"),
        ok_text = _("继续下载"),
        ok_callback = function() download(desktop, enable_after) end,
    }:show()
end

--- 已启用时切到词库未下载的布局，直接提示下载；否则候选栏会静默退回原生键盘。
---@param desktop BookDesktop
local function pickInputMethod(desktop)
    local IME = require("features.ime")
    local items = {}
    for _idx, method in ipairs(IME.layouts()) do
        items[#items + 1] = { text = method.label, value = method.id }
    end
    require("ui.themes.widgets.list"):new{
        title = _("键盘布局"),
        items = items,
        current = IME.layout(),
        centered = true,
        on_select = function(id)
            IME.setLayout(id)
            desktop:updateView()
            if IME.isEnabled() and not require("features.ime.registry").isAvailable(id) then
                confirmDownload(desktop)
            end
        end,
    }:show()
end

--- 候选词输出字形：keep 跟随词库（拼音 / 五笔多为简体，注音多为繁体）。
---@return table[]
local function scripts()
    return {
        { value = "keep", text = _("不转换") },
        { value = "simplified", text = _("转为简体") },
        { value = "traditional", text = _("转为繁体") },
    }
end

---@param id string
---@return string
local function scriptLabel(id)
    for _idx, item in ipairs(scripts()) do
        if item.value == id then return item.text end
    end
    return id
end

---@param desktop BookDesktop
local function pickScript(desktop)
    local Settings = require("utils.settings")
    require("ui.themes.widgets.list"):new{
        title = _("简繁转换"),
        items = scripts(),
        current = Settings.get("features.ime").ime_script,
        centered = true,
        on_select = function(id)
            local settings = Settings.get("features.ime")
            settings.ime_script = id
            Settings.save("features.ime", settings)
            desktop:updateView()
        end,
    }:show()
end

-- ── 输入方式 ─────────────────────────────────────────

---@param mode string
---@return string
local function modeLabel(mode)
    return mode == "system" and _("系统输入法") or _("KOReader 输入法")
end

--- 系统输入法的平台副标题；Android 不再写具体输入法示例。
---@param platform string
---@return string|nil
local function platformSubtitle(platform)
    if platform == "android" then
        return nil
    elseif platform == "windows" then
        return _("Windows 系统输入法（微软拼音等）")
    elseif platform == "macos" then
        return _("macOS 系统输入法")
    elseif platform == "linux" then
        return _("系统输入法（fcitx5 / ibus）")
    elseif platform == "wsl" then
        return _("WSL 不支持 Windows 输入法；需先装 fcitx5")
    end
    return _("KOReader 自带键盘")
end

--- WSL 的 fcitx5 准备说明；Android 不再显示说明文字。
---@return string
local function systemNote()
    return _("WSL 无法使用 Windows 输入法（微软拼音 / 微信输入法）。请先在 WSL 内安装 fcitx5，并用 fcitx5 --disable=wayland 启动，设置 XMODIFIERS=@im=fcitx 后再启动 KOReader。")
end

---@param text string
---@return fun(iw: number): table
local function noteRow(text)
    local Row = require("ui.themes.widgets.row")
    return function(iw) return Row.note(iw, text) end
end

--- 输入方式单选行；有双模式的平台才显示。
---@param desktop BookDesktop
---@param platform string
---@return fun(iw: number): table
local function modeRow(desktop, platform)
    local Row = require("ui.themes.widgets.row")
    return function(iw)
        return Row.choice{
            width = iw,
            icon = "keyboard",
            title = _("输入方式"),
            items = {
                { value = "system", text = _("系统输入法"), subtitle = platformSubtitle(platform) },
                { value = "builtin", text = _("KOReader 输入法") },
            },
            current = require("features.ime").inputMode(),
            on_select = function(mode)
                require("features.ime").setInputMode(mode)
                desktop:updateView()
            end,
        }
    end
end

---@param result string|nil
---@return string
local function testResultLabel(result)
    if result == "pass" then return _("通过") end
    if result == "fail" then return _("未通过") end
    return _("未测试")
end

--- 桌面 / WSL 的系统输入法手动测试入口；真实结果由 09 的后端写入 test_result。
---@param desktop BookDesktop
---@return fun(iw: number): table
local function testRow(desktop)
    local Row = require("ui.themes.widgets.row")
    return function(iw)
        local Settings = require("utils.settings")
        return Row.widget{
            width = iw,
            chevron = true,
            kind = "nav",
            icon = "keyboard_return",
            title = _("测试系统输入法"),
            status = testResultLabel(Settings.get("features.system_ime").test_result),
            callback = function()
                local backend = require("features.ime").backend()
                if backend.test then
                    backend.test(function()
                        if not desktop.closed then desktop:updateView() end
                    end)
                else
                    require("ui.themes.widgets.toast"):new{
                        text = _("系统输入法不可用"),
                        timeout = 2,
                    }:show()
                end
                desktop:updateView()
            end,
        }
    end
end

-- ── 页面分节 ─────────────────────────────────────────

--- 内置键盘的全部行（与输入方式 / 说明分开，便于按模式前缀）。
---@param desktop BookDesktop
---@return table[]
local function builtinRows(desktop)
    local IME = require("features.ime")
    local Registry = require("features.ime.registry")
    local Paths = require("utils.paths")
    local Row = require("ui.themes.widgets.row")
    local method = Registry.current()
    local dict_path = Paths.userPath(Paths.imeDictPath(method.dictionary))
    local keycaps_row = function(iw)
        local on = require("utils.settings").get("features.ime").ime_keycaps
        return Row.widget({
            width = iw,
            chevron = false,
            kind = "toggle",
            icon = "keyboard",
            title = _("显示字根键帽"),
            status = on and _("开") or _("关"),
            status_on = on,
            callback = function()
                local Settings = require("utils.settings")
                local settings = Settings.get("features.ime")
                settings.ime_keycaps = not settings.ime_keycaps
                Settings.save("features.ime", settings)
                desktop:updateView()
            end,
        })
    end
    local rows = {
                function(iw)
                    return Row.widget({
                        width = iw,
                        chevron = false,
                        kind = "toggle",
                        icon = "translate",
                        title = _("输入法"),
                        status = IME.isEnabled() and _("开") or _("关"),
                        status_on = IME.isEnabled(),
                        callback = function()
                            if not IME.isEnabled() and not Registry.isAvailable(method) then
                                confirmDownload(desktop, true)
                                return
                            end
                            local on = IME.setEnabled(not IME.isEnabled())
                            require("ui.themes.widgets.toast"):new{
                                text = on and _("中文键盘已启用，点键盘上的 🌐 键切换中英文") or _("中文键盘已停用"),
                                timeout = 3,
                            }:show()
                            desktop:updateView()
                        end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw,
                        chevron = true,
                        kind = "nav",
                        icon = "keyboard",
                        title = _("键盘布局"),
                        status = method.label,
                        status_on = true,
                        callback = function() pickInputMethod(desktop) end,
                    })
                end,
                function(iw)
                    local script = require("utils.settings").get("features.ime").ime_script
                    return Row.widget({
                        width = iw,
                        chevron = true,
                        kind = "nav",
                        icon = "g_translate",
                        title = _("简繁转换"),
                        status = scriptLabel(script),
                        status_on = script ~= "keep",
                        callback = function() pickScript(desktop) end,
                    })
                end,
                function(iw)
                    local settings = require("utils.settings").get("features.ime")
                    return Row.widget({
                        width = iw,
                        chevron = false,
                        kind = "toggle",
                        icon = "keyboard_hide",
                        title = _("键盘收起键"),
                        status = settings.hide_key and _("开") or _("关"),
                        status_on = settings.hide_key,
                        callback = function()
                            settings.hide_key = not settings.hide_key
                            require("utils.settings").save("features.ime", settings)
                            desktop:updateView()
                        end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw,
                        chevron = true,
                        kind = "nav",
                        icon = "spellcheck",
                        title = _("输入法词库"),
                        status = IME.dictStatus(),
                        status_on = Registry.isAvailable(method),
                        callback = function() confirmDownload(desktop) end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw,
                        chevron = true,
                        kind = "nav",
                        icon = "folder_open",
                        title = _("手动安装词库"),
                        subtitle = _("在线下载过慢时使用"),
                        callback = function()
                            require("ui.themes.widgets.text_viewer"):new{
                                title = _("手动安装词库"),
                                fullscreen = false,
                                text = T(_("1. 打开 GitHub Release：\n%1\n\n2. 下载当前输入法对应的词库文件。\n\n3. 放入：\n%2"),
                                    RELEASES_URL, dict_path),
                            }:show()
                        end,
                    })
                end,
    }
    if method.optional_labels then table.insert(rows, 3, keycaps_row) end
    return rows
end

--- system 模式分节：Android 一句说明；桌面 / WSL 测试入口；WSL 另给 fcitx5 指引。
---@param desktop BookDesktop
---@param platform string
---@return table
local function systemSection(desktop, platform)
    local rows = {}
    -- 只有 WSL 需要 fcitx5 准备说明；Android 的系统输入法不再加说明行。
    if platform == "wsl" then
        rows[#rows + 1] = noteRow(systemNote())
    end
    if platform == "android" then
        if require("utils.settings").get("features.system_ime").last_status == "not_ready" then
            rows[#rows + 1] = noteRow(_("上次启动未就绪"))
        end
    elseif platform == "windows" or platform == "macos" or platform == "linux"
            or platform == "wsl" then
        rows[#rows + 1] = testRow(desktop)
    end
    return { title = _("系统输入法"), rows = rows }
end

--- builtin 模式分节：内置键盘的全部行。
---@param desktop BookDesktop
---@return table
local function builtinSection(desktop)
    return { title = _("KOReader 输入法"), rows = builtinRows(desktop) }
end

--- 页面结构按 strategy §3.4：顶部「输入方式」，其下按当前模式只显示对应分节；
--- 墨水屏没有「输入方式」，只保留内置键盘分节。
---@param desktop BookDesktop
---@return table[]
local function sections(desktop)
    local platform = Platform.current()
    local eink = Platform.isEinkCurrent()
    local mode = require("features.ime").inputMode()
    local out = {}
    if not eink then
        out[#out + 1] = { rows = { modeRow(desktop, platform) } }
    end
    out[#out + 1] = mode == "system"
        and systemSection(desktop, platform)
        or builtinSection(desktop)
    return out
end

local Setting = {}

-- pinyin_enabled 是内置键盘总开关（键名沿用拼音时代）；input_mode 不设默认值，
-- nil 表示按平台默认，只在保存后用 keys 迁移。ime_layout 取 registry 的方法 id；
-- ime_dict_built_at 按词库记已装版本；ime_script 是候选词字形；
-- ime_keycaps 为真时五笔 / 仓颉 / 小鹤键盘把键帽换成字根 / 韵母。
Setting.defaults = {
    pinyin_enabled = false,
    ime_layout = "pinyin",
    ime_dict_built_at = {},
    ime_script = "keep",
    ime_keycaps = false,
    hide_key = true, -- 虚拟键盘末行的收起键，与中文输入法开关无关
}

Setting.keys = { "input_mode" }

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    local IME = require("features.ime")
    local platform = Platform.current()
    local mode = IME.inputMode()
    -- 不能写 `a and b or c`：Android 的 b 是 nil，会错误落成「KOReader 自带键盘」。
    local subtitle
    if mode == "system" then
        subtitle = platformSubtitle(platform)
    else
        subtitle = _("KOReader 自带键盘")
    end
    return {
        {
            id = "main",
            group = "system",
            order = 30,
            icon = "keyboard",
            title = _("输入法"),
            subtitle = subtitle,
            status = modeLabel(mode),
            status_on = mode == "system",
            page = {
                title = _("输入法"),
                docs = "/manual/system/local/ime",
                sections = function() return sections(desktop) end,
            },
        },
    }
end

return Setting
