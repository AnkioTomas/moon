--[[--
features.ime 输入方式契约：平台默认、显式选择、迁移、墨水屏、模式互斥与
数字 / 密码 / 只读路由。后端全部用假实现，不依赖真实 Android / SDL。

@module tests.features.ime.mode_spec
--]]

local Assert = require("support.assert")

-- ── 桩：平台（真实 defaultMode / backend 逻辑 + 可切换的当前平台）──
local RealPlatform = require("features.ime.platform")
package.loaded["features.ime.platform"] = nil
local platform_state = { platform = "android", eink = false }
package.preload["features.ime.platform"] = function()
    return {
        current = function() return platform_state.platform end,
        -- 真实墨水屏路径见 eink_spec；这里只切换判定结果。
        isEinkCurrent = function() return platform_state.eink end,
        defaultMode = RealPlatform.defaultMode,
        backend = RealPlatform.backend,
    }
end

-- ── 桩：配置（按 owner 分开存）──
local owners = {}
local save_calls = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner)
            owners[owner] = owners[owner] or {}
            return owners[owner]
        end,
        save = function(owner, values)
            if values and values ~= owners[owner] then owners[owner] = values end
            save_calls[#save_calls + 1] = owner
        end,
    }
end

local saved = {}
_G.G_reader_settings = {
    readSetting = function(_, key, default)
        local value = saved[key]
        if value == nil then return default end
        return value
    end,
    saveSetting = function(_, key, value) saved[key] = value end,
    delSetting = function(_, key) saved[key] = nil end,
}

-- ── 桩：候选栏 / 收起键 ──
local bar_calls = { install = 0, reset = 0, activate = 0 }
package.preload["features.ime.candidate_bar"] = function()
    return {
        install = function(opts)
            bar_calls.install = bar_calls.install + 1
            bar_calls.opts = opts
        end,
        reset = function() bar_calls.reset = bar_calls.reset + 1 end,
        activate = function() bar_calls.activate = bar_calls.activate + 1 end,
    }
end
package.preload["features.ime.hide_key"] = function()
    return { onCreate = function() end }
end

-- ── 桩：输入法注册表 ──
local profile = { id = "pinyin", label = "拼音", dictionary = "pinyin" }
package.preload["features.ime.registry"] = function()
    return {
        current = function() return profile end,
        get = function() return profile end,
        list = function() return { profile } end,
        isAvailable = function() return true end,
        fileExists = function() return true end,
        entries = function() return "100" end,
        builtAt = function() return "2026-08-19" end,
    }
end

-- ── 桩：假输入后端 ──
local function fakeBackend(state)
    return {
        available = function() return state.available end,
        show = function(vk)
            state.shown[#state.shown + 1] = vk
            return state.show_result
        end,
        hide = function(vk) state.hidden[#state.hidden + 1] = vk end,
        status = function() return state.status end,
        test = function()
            state.tests = state.tests + 1
            return true
        end,
    }
end

local android = { available = true, status = "ready", shown = {}, hidden = {}, tests = 0 }
local desktop = { available = true, status = "ready", shown = {}, hidden = {}, tests = 0 }
package.preload["features.system_ime"] = function() return fakeBackend(android) end
package.preload["features.system_text"] = function() return fakeBackend(desktop) end

-- ── 桩：VirtualKeyboard（记录原生 show/hide）──
local native_show, native_hide = 0, 0
local VK = {
    showKeyboard = function(self)
        native_show = native_show + 1
        self.visible = true
    end,
    hideKeyboard = function(self)
        native_hide = native_hide + 1
        self.visible = false
    end,
    isVisible = function(self) return self.visible == true end,
}
package.preload["ui/widget/virtualkeyboard"] = function() return VK end

local IME = require("features.ime")
local Backend = require("features.ime.backend")
local PREVIOUS = "book_pinyin_previous_keyboard_layouts"

local function reset(opts)
    opts = opts or {}
    platform_state.platform = opts.platform or "android"
    platform_state.eink = opts.eink == true
    owners["features.ime"] = opts.ime or {}
    owners["features.system_ime"] = opts.legacy or { enabled = true }
    saved.keyboard_layouts = opts.layouts or { "de", "en", "ru" }
    saved[PREVIOUS] = nil
    save_calls = {}
    bar_calls = { install = 0, reset = 0, activate = 0 }
    native_show, native_hide = 0, 0
    android.shown, android.hidden, android.tests = {}, {}, 0
    desktop.shown, desktop.hidden, desktop.tests = {}, {}, 0
    desktop.show_result = nil
end

-- ── 平台默认 ─────────────────────────────────────────
reset{ platform = "android" }
Assert.eq(IME.inputMode(), "system", "Android 默认系统输入法")

reset{ platform = "linux" }
Assert.eq(IME.inputMode(), "system", "Linux 默认系统输入法")

reset{ platform = "windows" }
Assert.eq(IME.inputMode(), "system", "Windows 默认系统输入法")

reset{ platform = "macos" }
Assert.eq(IME.inputMode(), "system", "macOS 默认系统输入法")

reset{ platform = "wsl" }
Assert.eq(IME.inputMode(), "builtin", "WSL 默认内置键盘")

reset{ platform = "kindle" }
Assert.eq(IME.inputMode(), "builtin", "Kindle 默认内置键盘")

reset{ platform = "kobo" }
Assert.eq(IME.inputMode(), "builtin", "Kobo 默认内置键盘")

-- ── 显式选择优先 ─────────────────────────────────────
reset{ platform = "android", ime = { input_mode = "builtin" } }
Assert.eq(IME.inputMode(), "builtin", "显式 builtin 覆盖 Android 默认")

reset{ platform = "wsl", ime = { input_mode = "system" } }
Assert.eq(IME.inputMode(), "system", "显式 system 覆盖 WSL 默认")

-- ── 迁移：旧 system_ime.enabled == false → builtin，只写一次 ──
reset{ platform = "android", legacy = { enabled = false } }
Assert.eq(IME.inputMode(), "builtin", "旧开关关闭时迁移为 builtin")
Assert.eq(owners["features.ime"].input_mode, "builtin", "迁移写入 input_mode")
Assert.contains(save_calls, "features.ime")

reset{ platform = "android", legacy = { enabled = true } }
Assert.eq(IME.inputMode(), "system", "旧开关开启时走平台默认")
Assert.eq(owners["features.ime"].input_mode, "system", "首次迁移把平台默认写进 input_mode")

-- 迁移只做一次：写入后旧键不再参与，重复调用不再保存
local saves_after_migration = #save_calls
owners["features.system_ime"].enabled = false
Assert.eq(IME.inputMode(), "system", "迁移后旧键改回 false 也不影响")
Assert.eq(owners["features.ime"].input_mode, "system", "已迁移值保持不变")
Assert.eq(#save_calls, saves_after_migration, "重复 inputMode 不重复落盘")

-- 迁移完成后旧键不再参与计算
reset{ platform = "android", ime = { input_mode = "system" }, legacy = { enabled = false } }
Assert.eq(IME.inputMode(), "system", "已有 input_mode 时忽略旧键")

-- ── 墨水屏强制 builtin，忽略存储值 ────────────────────
reset{ platform = "android", eink = true, ime = { input_mode = "system" } }
Assert.eq(IME.inputMode(), "builtin", "墨水屏忽略显式 system")

reset{ platform = "linux", eink = true }
Assert.eq(IME.inputMode(), "builtin", "桌面墨水屏也强制 builtin")

-- ── setInputMode：写入并立即应用 ──────────────────────
reset{ platform = "android", ime = { pinyin_enabled = true }, layouts = { "de", "en", "ru" } }
IME.setInputMode("builtin")
Assert.eq(owners["features.ime"].input_mode, "builtin")
Assert.eq(saved.keyboard_layouts[1], "en", "切到 builtin 后收紧布局")
Assert.eq(saved.keyboard_layouts[2], "zh_CN")
Assert.eq(saved[PREVIOUS][1], "de", "保留拼音前布局快照")
Assert.is_true(bar_calls.install > 0, "builtin 安装候选栏钩子")
Assert.is_true(bar_calls.activate > 0, "builtin 激活候选栏")
Assert.is_true(bar_calls.opts.enabled(), "enabled 判定为真")

-- 切到 system：候选栏停用、布局恢复、拼音开关保留
local install_before = bar_calls.install
IME.setInputMode("system")
Assert.eq(owners["features.ime"].input_mode, "system")
Assert.is_true(bar_calls.reset > 0, "system 模式 reset 候选栏")
Assert.eq(bar_calls.install, install_before, "system 模式不再安装候选栏")
Assert.eq(saved.keyboard_layouts[1], "de", "system 模式恢复拼音前布局")
Assert.eq(saved.keyboard_layouts[3], "ru")
Assert.not_nil(saved[PREVIOUS], "恢复布局时保留快照")
Assert.is_true(owners["features.ime"].pinyin_enabled, "system 模式保留拼音开关值")
Assert.is_false(bar_calls.opts.enabled(), "system 模式下 enabled 判定为假")

-- 切回 builtin：重新收紧布局并激活候选栏
IME.setInputMode("builtin")
Assert.eq(saved.keyboard_layouts[1], "en", "切回 builtin 重新收紧布局")
Assert.eq(saved.keyboard_layouts[2], "zh_CN")
Assert.is_true(bar_calls.activate > 0)
Assert.is_true(bar_calls.opts.enabled(), "回 builtin 后 enabled 判定恢复")

-- 关闭拼音：恢复布局并删除快照
IME.setEnabled(false)
Assert.eq(saved.keyboard_layouts[1], "de", "关闭拼音恢复最初布局")
Assert.eq(saved.keyboard_layouts[3], "ru")
Assert.is_nil(saved[PREVIOUS], "关闭拼音删除快照")

-- ── 后端接口：available / show / hide / status / test ──
reset{ platform = "android", ime = { input_mode = "system" } }
IME.installRouting()
local backend = IME.backend()
Assert.eq(backend.name, "features.system_ime", "Android 选 system_ime")
Assert.is_true(backend.available())
Assert.eq(backend.status(), "ready")
Assert.eq(type(backend.test), "function")
backend.test()
Assert.eq(android.tests, 1, "test 入口可用")

-- system 模式：交给假后端，不弹原生 VK
local vk = { inputbox = {} }
VK.showKeyboard(vk)
Assert.eq(#android.shown, 1, "system 模式调用后端 show")
Assert.eq(native_show, 0, "system 模式不显示 VK")
VK.hideKeyboard(vk)
Assert.eq(#android.hidden, 1, "system 模式调用后端 hide")

-- system 后端 show 失败（dex 缺失 / SDL 起不来）：必须当场回退原生键盘
reset{ platform = "android", ime = { input_mode = "system" } }
android.show_result = false
local failed = { inputbox = {} }
VK.showKeyboard(failed)
Assert.eq(#android.shown, 1, "失败前仍尝试系统后端")
Assert.eq(native_show, 1, "系统后端失败后回退原生 VK")
android.show_result = nil

-- 从 builtin 切过来时旧 VK 还开着：system show 必须先收掉，避免两套键盘同现
reset{ platform = "android", ime = { input_mode = "system" } }
local stale = setmetatable({ inputbox = {}, visible = true }, { __index = VK })
VK.showKeyboard(stale)
Assert.eq(#android.shown, 1, "系统后端仍然收到 show")
Assert.eq(native_hide, 1, "残留 VK 必须先收起")
Assert.is_false(stale.visible, "system 模式下 VK 不可见")
Assert.eq(native_show, 0, "system 模式不显示 VK")

-- ── 数字 / 密码：system 模式仍走内置键盘 ──────────────
local cases = {
    { name = "number", inputbox = { input_type = "number" } },
    { name = "password text_type", inputbox = { text_type = "password" } },
    { name = "password is_password_type", inputbox = { is_password_type = true } },
}
for _idx, case in ipairs(cases) do
    android.shown = {}
    native_show = 0
    local field = { inputbox = case.inputbox }
    VK.showKeyboard(field)
    Assert.eq(#android.shown, 0, case.name .. " 不交给系统后端")
    Assert.eq(native_show, 1, case.name .. " 走内置键盘")
end

-- ── 只读：不弹任何键盘 ────────────────────────────────
android.shown = {}
native_show = 0
VK.showKeyboard({ inputbox = { readonly = true } })
Assert.eq(#android.shown, 0, "只读不交给系统后端")
Assert.eq(native_show, 0, "只读不弹内置键盘")

-- 只读字段之前内置键盘还开着：顺手收起，避免残留
reset{ platform = "android", ime = { input_mode = "system" } }
local open_vk = setmetatable({ inputbox = {}, visible = true }, { __index = VK })
VK.showKeyboard(open_vk)
native_show = 0
open_vk.inputbox = { readonly = true }
VK.showKeyboard(open_vk)
Assert.eq(native_show, 0, "只读不再显示键盘")
Assert.is_false(open_vk.visible, "只读时收起残留 VK")

-- ── builtin 模式：原生 VK ────────────────────────────
reset{ platform = "android", ime = { input_mode = "builtin" } }
android.shown = {}
native_show = 0
VK.showKeyboard({ inputbox = {} })
Assert.eq(#android.shown, 0, "builtin 模式不调用系统后端")
Assert.eq(native_show, 1, "builtin 模式显示 VK")

-- ── 后端不可用：降级为原生 VK ────────────────────────
reset{ platform = "android", ime = { input_mode = "system" } }
android.available = false
android.shown = {}
native_show = 0
VK.showKeyboard({ inputbox = {} })
Assert.eq(#android.shown, 0, "后端不可用时不调用 show")
Assert.eq(native_show, 1, "后端不可用降级内置键盘")
android.available = true

-- 桌面后端选择
platform_state.platform = "linux"
Assert.eq(IME.backend().name, "features.system_text", "桌面选 system_text")
desktop.shown = {}
VK.showKeyboard({ inputbox = {} })
Assert.eq(#desktop.shown, 1, "桌面 system 模式交给 system_text")

-- 桌面后端拿不到 SDL 文本输入：show 返回 false，当场回退原生 VK
reset{ platform = "linux", ime = { input_mode = "system" } }
desktop.show_result = false
VK.showKeyboard({ inputbox = {} })
Assert.eq(#desktop.shown, 1, "失败前仍尝试桌面后端")
Assert.eq(native_show, 1, "桌面后端失败后回退原生 VK")
desktop.show_result = nil

-- 没有后端的平台：不可用后端
platform_state.platform = "kindle"
local unavailable = IME.backend()
Assert.eq(unavailable.name, "none")
Assert.is_false(unavailable.available())
Assert.eq(unavailable.status(), "unavailable")
unavailable.show({})
unavailable.hide({})

-- 模块缺失也降级为不可用（不抛错）
local missing = Backend.load("features.no_such_backend")
Assert.is_false(missing.available())
Assert.eq(missing.status(), "unavailable")
missing.show({})
missing.hide({})
Assert.is_nil(missing.test, "没有 test 时保持可选")
