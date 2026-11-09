--[[--
features.ime.setting：唯一「输入法」入口、输入方式选择、按模式显示的行、
平台副标题、三语文案与桌面 / WSL 测试行。

@module tests.features.ime.setting_spec
--]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end
package.preload["ffi/util"] = function()
    return { template = function(text) return text end }
end

-- 行 / 说明 / 单选都用轻量替身，只断言渲染结果与回调。
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts) return opts end,
        note = function(width, text) return { note = text, width = width } end,
        choice = function(opts)
            opts.choice = true
            return opts
        end,
    }
end

local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    return {
        new = function(_, opts)
            return { show = function() toasts[#toasts + 1] = opts.text end }
        end,
    }
end

-- 配置按拥有者分开
local owners = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner)
            owners[owner] = owners[owner] or {}
            return owners[owner]
        end,
        save = function() end,
    }
end

local registry_method = { id = "pinyin", label = "拼音", dictionary = "pinyin" }
package.preload["utils.paths"] = function()
    return {
        userPath = function(path) return "/data" .. path end,
        imeDictPath = function(name) return "/ime/" .. name end,
    }
end
package.preload["features.ime.registry"] = function()
    return {
        current = function() return registry_method end,
        get = function() return registry_method end,
        list = function() return { registry_method } end,
        isAvailable = function() return true end,
    }
end

-- 平台与输入方式状态
local state = {
    platform = "android",
    eink = false,
    mode = "system",
    enabled = true,
    backend = nil,
}
package.preload["features.ime.platform"] = function()
    return {
        current = function() return state.platform end,
        isEinkCurrent = function() return state.eink end,
        isEink = function() return state.eink end,
    }
end
package.preload["features.ime"] = function()
    return {
        inputMode = function()
            if state.eink then return "builtin" end
            return state.mode
        end,
        setInputMode = function(mode)
            state.mode = mode
            return true
        end,
        isEnabled = function() return state.enabled end,
        setEnabled = function(value)
            state.enabled = value
            return value
        end,
        layout = function() return "pinyin" end,
        layouts = function() return { registry_method } end,
        dictStatus = function() return "7.4 万 · 2026-08-19" end,
        backend = function() return state.backend end,
    }
end

local desktop = { updates = 0 }
function desktop:updateView() self.updates = self.updates + 1 end

local Setting = require("features.ime.setting")

local function reset(opts)
    opts = opts or {}
    state.platform = opts.platform or "android"
    state.eink = opts.eink == true
    state.mode = opts.mode or "system"
    state.enabled = opts.enabled ~= false
    state.backend = opts.backend
    owners["features.ime"] = {
        pinyin_enabled = state.enabled,
        ime_layout = "pinyin",
        ime_script = "keep",
        ime_keycaps = false,
        hide_key = true,
    }
    owners["features.system_ime"] = {
        enabled = true,
        last_status = opts.last_status,
        test_result = opts.test_result,
    }
    desktop.updates = 0
    toasts = {}
end

---@param entry table
---@return table[]
local function rowsOf(entry)
    local rows = {}
    for _idx, section in ipairs(entry.page.sections()) do
        for _j, build in ipairs(section.rows) do
            rows[#rows + 1] = build(400)
        end
    end
    return rows
end

---@param entry table
---@return string[]
local function sectionTitles(entry)
    local titles = {}
    for _idx, section in ipairs(entry.page.sections()) do
        if section.title then titles[#titles + 1] = section.title end
    end
    return titles
end

local function titleRow(rows, predicate)
    for _idx, row in ipairs(rows) do
        if predicate(row) then return row end
    end
end

local function byTitle(rows, title)
    return titleRow(rows, function(row) return row.title == title end)
end

local function hasTitle(rows, title)
    return byTitle(rows, title) ~= nil
end

-- ── 唯一入口 ─────────────────────────────────────────
reset{}
local entries = Setting.entries(desktop)
Assert.len(entries, 1, "设置页只剩一个输入法入口")
local entry = entries[1]
Assert.eq(entry.id, "main")
Assert.eq(entry.group, "system")
Assert.eq(entry.order, 30)
Assert.eq(entry.title, "输入法")
Assert.is_nil(require("features.ime.setting").defaults.input_mode, "input_mode 不设默认值")
Assert.contains(Setting.keys, "input_mode")

-- ── Android system：只有输入方式（不再有说明行） ───────
reset{ platform = "android", mode = "system" }
entry = Setting.entries(desktop)[1]
Assert.eq(entry.status, "系统输入法")
Assert.is_nil(entry.subtitle, "Android 不再写输入法示例副标题")
local rows = rowsOf(entry)
Assert.len(rows, 1, "Android system 只有输入方式")
Assert.eq(table.concat(sectionTitles(entry), ","), "系统输入法", "system 模式只有系统输入法分节")
local mode_row = byTitle(rows, "输入方式")
Assert.is_true(mode_row.choice, "输入方式用 Row.choice")
Assert.eq(mode_row.current, "system")
Assert.eq(mode_row.items[1].text, "系统输入法")
Assert.is_nil(mode_row.items[1].subtitle, "系统输入法不再带平台副标题")
Assert.eq(mode_row.items[2].text, "KOReader 输入法")
Assert.is_nil(mode_row.items[2].subtitle)
Assert.is_false(hasTitle(rows, "键盘布局"), "system 模式不显示内置键盘行")
Assert.is_false(hasTitle(rows, "测试系统输入法"), "Android 不显示测试行")

mode_row.on_select("builtin")
Assert.eq(state.mode, "builtin")
Assert.eq(desktop.updates, 1, "切换输入方式后刷新设置页")

-- ── Android builtin：输入方式 + 全部内置键盘行 ─────────
reset{ platform = "android", mode = "builtin" }
entry = Setting.entries(desktop)[1]
Assert.eq(entry.status, "KOReader 输入法")
Assert.eq(entry.subtitle, "KOReader 自带键盘")
rows = rowsOf(entry)
Assert.eq(table.concat(sectionTitles(entry), ","), "KOReader 输入法", "builtin 模式只有内置输入法分节")
Assert.eq(byTitle(rows, "输入方式").current, "builtin")
for _idx, title in ipairs({
    "输入法", "键盘布局", "简繁转换", "键盘收起键", "输入法词库", "手动安装词库",
}) do
    Assert.is_true(hasTitle(rows, title), "builtin 模式应有行：" .. title)
end
Assert.is_false(hasTitle(rows, "测试系统输入法"), "Android 不显示测试行")
for _idx, row in ipairs(rows) do
    Assert.is_nil(row.note, "内置键盘分节不再额外插说明")
end

-- ── 桌面 system：说明 + 测试行 ───────────────────────
reset{ platform = "linux", mode = "system" }
entry = Setting.entries(desktop)[1]
Assert.eq(entry.subtitle, "系统输入法（fcitx5 / ibus）")
rows = rowsOf(entry)
Assert.len(rows, 2, "桌面 system 有输入方式 + 测试")
Assert.eq(table.concat(sectionTitles(entry), ","), "系统输入法")
Assert.eq(byTitle(rows, "输入方式").items[1].subtitle, "系统输入法（fcitx5 / ibus）")
Assert.is_nil(rows[2].note, "桌面不额外插系统说明")
local test_row = byTitle(rows, "测试系统输入法")
Assert.not_nil(test_row)
Assert.eq(test_row.status, "未测试")

-- 测试结果映射
reset{ platform = "linux", mode = "system", test_result = "pass" }
Assert.eq(byTitle(rowsOf(Setting.entries(desktop)[1]), "测试系统输入法").status, "通过")
reset{ platform = "linux", mode = "system", test_result = "fail" }
Assert.eq(byTitle(rowsOf(Setting.entries(desktop)[1]), "测试系统输入法").status, "未通过")

-- 点测试行：后端有 test 就调用并刷新
local tested = 0
reset{
    platform = "linux",
    mode = "system",
    backend = { test = function() tested = tested + 1 end },
}
test_row = byTitle(rowsOf(Setting.entries(desktop)[1]), "测试系统输入法")
test_row.callback()
Assert.eq(tested, 1, "测试行调用后端 test")
Assert.eq(desktop.updates, 1)

-- 后端没有 test：提示不可用，不崩溃
reset{ platform = "linux", mode = "system", backend = {} }
test_row = byTitle(rowsOf(Setting.entries(desktop)[1]), "测试系统输入法")
test_row.callback()
Assert.eq(toasts[1], "系统输入法不可用")
Assert.eq(desktop.updates, 1)

-- 测试结束（异步对话框关闭）后再刷新设置页，结果立即可见
reset{
    platform = "linux",
    mode = "system",
    backend = { test = function(done) done() end },
}
test_row = byTitle(rowsOf(Setting.entries(desktop)[1]), "测试系统输入法")
test_row.callback()
Assert.is_true(desktop.updates >= 2, "测试完成后刷新设置页")

-- Windows / macOS 副标题
reset{ platform = "windows", mode = "system" }
Assert.eq(Setting.entries(desktop)[1].subtitle, "Windows 系统输入法（微软拼音等）")
reset{ platform = "macos", mode = "system" }
Assert.eq(Setting.entries(desktop)[1].subtitle, "macOS 系统输入法")

-- ── WSL system：警示说明 + 测试行 ────────────────────
reset{ platform = "wsl", mode = "system" }
entry = Setting.entries(desktop)[1]
Assert.eq(entry.subtitle, "WSL 不支持 Windows 输入法；需先装 fcitx5")
rows = rowsOf(entry)
Assert.len(rows, 3)
Assert.is_true(rows[2].note:find("fcitx5", 1, true) ~= nil, "WSL 文案必须提到 fcitx5")
Assert.is_true(rows[2].note:find("fcitx5 --disable=wayland", 1, true) ~= nil, "WSL 文案给出 fcitx5 启动参数")
Assert.is_true(rows[2].note:find("XMODIFIERS=@im=fcitx", 1, true) ~= nil, "WSL 文案给出 XMODIFIERS")
Assert.is_true(rows[2].note:find("Windows 输入法", 1, true) ~= nil, "WSL 文案说明 Windows 输入法不可用")
Assert.not_nil(byTitle(rows, "测试系统输入法"))

-- ── 墨水屏：没有「输入方式」行，只有内置键盘 ───────────
reset{ platform = "kindle", eink = true, mode = "system" }
entry = Setting.entries(desktop)[1]
Assert.eq(entry.status, "KOReader 输入法", "墨水屏强制 builtin")
Assert.eq(entry.subtitle, "KOReader 自带键盘")
rows = rowsOf(entry)
Assert.is_false(hasTitle(rows, "输入方式"), "Kindle / Kobo 不出现输入方式")
Assert.is_true(hasTitle(rows, "输入法"))
Assert.is_true(hasTitle(rows, "键盘布局"))

-- ── Android 上次启动未就绪 ───────────────────────────
reset{ platform = "android", mode = "system", last_status = "not_ready" }
rows = rowsOf(Setting.entries(desktop)[1])
Assert.eq(#rows, 2, "系统说明行去掉后只剩输入方式 + 未就绪提示")
Assert.eq(rows[2].note, "上次启动未就绪")
