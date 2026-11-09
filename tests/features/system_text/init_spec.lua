--[[--
features.system_text：桌面 / WSL 的 SDL 文本输入后端。

用假 Device、假 SDL 与可切换的平台状态验证 available / show / hide / status /
test；不依赖真实 SDL 窗口或桌面会话。

@module tests.features.system_text.init_spec
--]]

local Assert = require("support.assert")

-- 模拟 KOReader 的 ffi/SDL3_h.lua 已声明的不透明窗口与矩形。
local ffi = require("ffi")
pcall(ffi.cdef, [[
    typedef struct SDL_Window SDL_Window;
    typedef struct SDL_Rect SDL_Rect;
    struct SDL_Rect { int x, y, w, h; };
]])

-- Device：记录 start / stop 调用；由共享的 Platform.currentDevice() 取到
local device = { started = 0, stopped = 0, fail_start = false }
function device:startTextInput()
    if self.fail_start then error("SDL text input unavailable") end
    self.started = self.started + 1
end
function device:stopTextInput()
    self.stopped = self.stopped + 1
end

-- 平台：只提供 system_text 需要的当前平台与墨水屏判定
local platform = { name = "linux", eink = false }
package.preload["features.ime.platform"] = function()
    return {
        current = function() return platform.name end,
        isEinkCurrent = function() return platform.eink end,
        currentDevice = function() return device end,
    }
end

-- 防回归：绕过 Platform 直接 require("device") 会拿到另一个对象
package.preload["device"] = function()
    return {
        startTextInput = function() device.bypassed = true end,
        stopTextInput = function() device.bypassed = true end,
    }
end

-- 延迟重试：记录 show 之后排的 SDL_SetTextInputArea 重试
local scheduled = {}
package.preload["ui/uimanager"] = function()
    local UIManager = {}
    function UIManager:scheduleIn(delay, fn)
        scheduled[#scheduled + 1] = { delay = delay, fn = fn }
    end
    function UIManager:unschedule() end
    return UIManager
end

-- gettext / l10n
package.preload["gettext"] = function() return function(text) return text end end
package.preload["l10n"] = function() return { apply = function() end } end

-- 配置：按 owner 分开存
local owners = {}
local saved = {}
package.preload["utils.settings"] = function()
    return {
        get = function(owner)
            owners[owner] = owners[owner] or {}
            return owners[owner]
        end,
        save = function(owner, values)
            owners[owner] = values
            saved[#saved + 1] = owner
        end,
    }
end

-- 测试对话框：只捕获回调，由用例决定通过 / 未通过
local runner_cb
package.preload["features.system_text.test"] = function()
    return {
        run = function(cb) runner_cb = cb end,
    }
end

-- Toast：记录最后一条提示
local toasts = {}
package.preload["ui.themes.widgets.toast"] = function()
    return {
        new = function(_, opts)
            return { show = function() toasts[#toasts + 1] = opts.text end }
        end,
    }
end

-- SDL：假窗口、假符号表；screen 为 nil 时模拟没有窗口句柄
local sdl = { screen = {}, calls = {}, lib = nil }
local function area_lib()
    return {
        SDL_SetTextInputArea = function(window, rect, cursor)
            sdl.calls[#sdl.calls + 1] = {
                window = window,
                x = rect.x, y = rect.y, w = rect.w, h = rect.h,
                cursor = cursor,
            }
            return true
        end,
    }
end
sdl.lib = area_lib()
package.preload["ffi/SDL3"] = function()
    return setmetatable({}, {
        __index = function(_, key)
            if key == "screen" then return sdl.screen end
        end,
    })
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d+)", function(i) return tostring(args[tonumber(i)] or "") end))
        end,
        loadSDL3 = function() return sdl.lib end,
    }
end

-- 只让测试控制的 XMODIFIERS 生效，避免开发机真实环境干扰
local env_vars = {}
local real_getenv = os.getenv
os.getenv = function(name)
    if name == "XMODIFIERS" then return env_vars.XMODIFIERS end
    return real_getenv(name)
end

local SystemText = require("features.system_text")

--- 模拟新会话：模块级提示 / 活动状态重置。
local function fresh()
    package.loaded["features.system_text"] = nil
    SystemText = require("features.system_text")
end

local function reset(opts)
    opts = opts or {}
    platform.name = opts.platform or "linux"
    platform.eink = opts.eink == true
    env_vars = opts.env or {}
    device.started, device.stopped, device.bypassed = 0, 0, nil
    device.fail_start = opts.fail_start == true
    sdl.screen = opts.screen ~= false and {} or nil
    sdl.calls = {}
    sdl.lib = opts.lib or area_lib()
    owners["features.system_ime"] = opts.system_ime or {}
    saved = {}
    toasts = {}
    scheduled = {}
    runner_cb = nil
end

--- 跑一遍 show 之后排的锚点重试
local function runRetries()
    local pending = scheduled
    scheduled = {}
    for _idx, item in ipairs(pending) do item.fn() end
end

local function inputbox()
    return {
        dimen = { x = 10, y = 20, w = 300, h = 40 },
        charlist = { "你", "好" },
        charpos = 3,
    }
end

-- ── available：仅桌面 / WSL，Android 与墨水屏不可用 ─────────
for _idx, name in ipairs({ "linux", "windows", "macos", "wsl" }) do
    reset{ platform = name }
    Assert.is_true(SystemText.available(), name .. " 可用")
end

for _idx, name in ipairs({ "android", "kindle", "kobo", "pocketbook" }) do
    reset{ platform = name }
    Assert.is_false(SystemText.available(), name .. " 不可用")
    Assert.eq(SystemText.status(), "unavailable", name .. " 状态不可用")
end

reset{ platform = "linux", eink = true }
Assert.is_false(SystemText.available(), "桌面墨水屏不可用")
Assert.eq(SystemText.status(), "unavailable")

-- ── show / hide：桌面直接开 SDL 文本输入 ───────────────────
reset{ platform = "linux" }
Assert.eq(SystemText.status(), "ready")
Assert.is_true(SystemText.show({ inputbox = inputbox() }))
Assert.eq(device.started, 1, "show 调 startTextInput")
Assert.eq(#sdl.calls, 1, "show 设置候选窗锚点")
local call = sdl.calls[1]
Assert.eq(call.x, 10)
Assert.eq(call.y, 20)
Assert.eq(call.w, 300)
Assert.eq(call.h, 40)
Assert.eq(call.cursor, 6, "cursor 是按字节计的 caret 偏移")
SystemText.hide({ inputbox = inputbox() })
Assert.eq(device.stopped, 1, "hide 调 stopTextInput")

-- 没有输入框 / 没有 dimen：仍然开文本输入，只是不设锚点
reset{ platform = "linux" }
Assert.is_true(SystemText.show({}))
Assert.eq(device.started, 1)
Assert.eq(#sdl.calls, 0, "没有输入框时不调 SDL_SetTextInputArea")

reset{ platform = "linux" }
Assert.is_true(SystemText.show({ inputbox = {} }))
Assert.eq(#sdl.calls, 0, "没有 dimen 时不调 SDL_SetTextInputArea")

-- ── 候选窗锚点：show 时没有 dimen，稍后重试补上 ─────────
reset{ platform = "linux" }
local late = inputbox()
late.dimen = nil
Assert.is_true(SystemText.show({ inputbox = late }))
Assert.eq(#sdl.calls, 0, "首绘前没有坐标")
late.dimen = { x = 1, y = 2, w = 3, h = 4 }
runRetries()
Assert.eq(#sdl.calls, 2, "两次重试都补上候选窗锚点")
Assert.eq(sdl.calls[2].x, 1)

-- hide 之后不再补锚点
reset{ platform = "linux" }
late = inputbox()
late.dimen = nil
SystemText.show({ inputbox = late })
SystemText.hide({ inputbox = late })
late.dimen = { x = 1, y = 2, w = 3, h = 4 }
runRetries()
Assert.eq(#sdl.calls, 0, "收起后重试不再设置锚点")

-- 重复 show 立即重新设置锚点
reset{ platform = "linux" }
late = inputbox()
late.dimen = nil
SystemText.show({ inputbox = late })
late.dimen = { x = 4, y = 5, w = 6, h = 7 }
SystemText.show({ inputbox = late })
Assert.eq(#sdl.calls, 1, "重复 show 重设锚点")

-- ── SDL 降级：符号缺失 / 窗口句柄缺失都不崩 ───────────────
reset{
    platform = "linux",
    lib = setmetatable({}, { __index = function() error("missing symbol") end }),
}
Assert.is_true(SystemText.show({ inputbox = inputbox() }))
Assert.eq(device.started, 1, "符号缺失仍开文本输入")
Assert.eq(#sdl.calls, 0)

reset{ platform = "linux", screen = false }
Assert.is_true(SystemText.show({ inputbox = inputbox() }))
Assert.eq(device.started, 1, "没有窗口句柄仍开文本输入")
Assert.eq(#sdl.calls, 0)

-- ── WSL：只有 XMODIFIERS 指向 fcitx 才 ready ───────────────
fresh()
reset{ platform = "wsl", env = {} }
Assert.is_true(SystemText.available(), "WSL 后端存在")
Assert.eq(SystemText.status(), "not_ready", "WSL 未配置 fcitx 时未就绪")
Assert.is_false(SystemText.show({ inputbox = inputbox() }), "未就绪时 show 返回 false")
Assert.eq(device.started, 0, "未就绪不启动文本输入")
Assert.eq(toasts[1], "系统输入法不可用，已切回内置键盘", "未就绪回退要提示")
SystemText.show({ inputbox = inputbox() })
Assert.len(toasts, 1, "同一会话只提示一次")

reset{ platform = "wsl", env = { XMODIFIERS = "@im=ibus" } }
Assert.eq(SystemText.status(), "not_ready", "ibus 不算 fcitx 就绪")
Assert.is_false(SystemText.show({ inputbox = inputbox() }))

reset{ platform = "wsl", env = { XMODIFIERS = "@im=fcitx" } }
Assert.eq(SystemText.status(), "ready")
Assert.is_true(SystemText.show({ inputbox = inputbox() }))
Assert.eq(device.started, 1)

-- 其它桌面平台不因 XMODIFIERS 缺失而 not_ready
reset{ platform = "windows", env = {} }
Assert.eq(SystemText.status(), "ready")
Assert.is_true(SystemText.show({ inputbox = inputbox() }))

-- startTextInput 失败：回退 + 提示一次
fresh()
reset{ platform = "linux", fail_start = true }
Assert.is_false(SystemText.show({ inputbox = inputbox() }), "SDL 起不来时 show 返回 false")
Assert.eq(toasts[1], "系统输入法不可用，已切回内置键盘", "启动失败要提示")
SystemText.show({ inputbox = inputbox() })
Assert.len(toasts, 1, "同一会话只提示一次")

-- ── reset：只复位活动会话，不重新打开文本输入 ───────────────
reset{ platform = "linux" }
SystemText.show({ inputbox = inputbox() })
Assert.is_true(SystemText.reset())
Assert.eq(device.stopped, 1, "reset 停掉活动会话，丢弃预编辑")
Assert.eq(device.started, 1, "reset 不重新 startTextInput")
Assert.is_false(SystemText.reset(), "已经收起时 reset 是空操作")
Assert.eq(device.stopped, 1, "空操作不再 stop")

-- ── test：真实输入结果落到 features.system_ime.test_result ──
reset{ platform = "linux", system_ime = {} }
Assert.is_true(SystemText.test(), "桌面 test 打开测试输入")
Assert.is_true(type(runner_cb) == "function")
runner_cb(true)
Assert.eq(owners["features.system_ime"].test_result, "pass", "输入到文字记为通过")
Assert.contains(saved, "features.system_ime")
Assert.eq(toasts[1], "测试通过：输入框收到了文字")

reset{ platform = "linux", system_ime = {} }
SystemText.test()
runner_cb(false)
Assert.eq(owners["features.system_ime"].test_result, "fail", "没有输入文字记为未通过")
Assert.eq(toasts[1], "测试未通过：输入框没有收到文字，请检查系统输入法")

-- 平台不支持时不打开测试框，也不写结果
reset{ platform = "android", system_ime = {} }
Assert.is_false(SystemText.test())
Assert.is_nil(runner_cb)
Assert.is_nil(owners["features.system_ime"].test_result)

-- 未就绪（WSL 没装 fcitx5）不能把空测试记成通过
fresh()
reset{ platform = "wsl", env = {}, system_ime = {} }
local done_ok
Assert.is_false(SystemText.test(function(ok) done_ok = ok end), "未就绪时拒绝打开测试框")
Assert.is_nil(runner_cb, "不弹测试输入框")
Assert.eq(owners["features.system_ime"].test_result, "fail", "记录未通过")
Assert.eq(done_ok, false, "回调 false")
Assert.matches(toasts[1], "未就绪")
Assert.contains(saved, "features.system_ime")
