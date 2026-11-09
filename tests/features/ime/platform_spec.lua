--[[--
features.ime.platform：平台判定、默认输入方式与后端选择。

纯函数缝：detect(device, env, os_name) 不读全局，方便在 Android / 桌面 /
WSL / 墨水屏四种判定下重放。

@module tests.features.ime.platform_spec
--]]

local Assert = require("support.assert")

local Platform = require("features.ime.platform")

---@param flags table 如 { isAndroid = true, hasEinkScreen = true }
local function device(flags)
    local d = {}
    for _idx, name in ipairs({
        "isKindle", "isKobo", "isPocketBook", "isAndroid", "isSDL", "hasEinkScreen",
    }) do
        d[name] = function() return flags[name] == true end
    end
    return d
end

local function env(vars)
    return {
        getenv = function(name) return vars[name] end,
    }
end

-- Android 优先于 Linux（Android 的 ffi.os 也是 Linux）
Assert.eq(Platform.detect(device{ isAndroid = true }, env{}, "Linux"), "android")

-- 墨水屏阅读器按机型识别
Assert.eq(Platform.detect(device{ isKindle = true }, env{}, "Linux"), "kindle")
Assert.eq(Platform.detect(device{ isKobo = true }, env{}, "Linux"), "kobo")
Assert.eq(Platform.detect(device{ isPocketBook = true }, env{}, "Linux"), "pocketbook")

-- 桌面三平台按 ffi.os 区分
Assert.eq(Platform.detect(device{ isSDL = true }, env{}, "Windows"), "windows")
Assert.eq(Platform.detect(device{ isSDL = true }, env{}, "OSX"), "macos")
Assert.eq(Platform.detect(device{ isSDL = true }, env{}, "Linux"), "linux")

-- WSL 仍是 Linux，但环境变量明确标记
Assert.eq(Platform.detect(device{ isSDL = true }, env{ WSL_DISTRO_NAME = "Ubuntu" }, "Linux"), "wsl")
Assert.eq(Platform.detect(device{ isSDL = true }, env{ WSL_INTEROP = "/run/WSL/1_interop" }, "Linux"), "wsl")

-- 墨水屏判定独立于平台：Android 电纸书也要走内置键盘
Assert.is_true(Platform.isEink(device{ isAndroid = true, hasEinkScreen = true }))
Assert.is_false(Platform.isEink(device{ isAndroid = true }))
Assert.is_false(Platform.isEink(nil))

-- 平台默认：Android / Windows / macOS / Linux = system；其余 = builtin
Assert.eq(Platform.defaultMode("android"), "system")
Assert.eq(Platform.defaultMode("windows"), "system")
Assert.eq(Platform.defaultMode("macos"), "system")
Assert.eq(Platform.defaultMode("linux"), "system")
Assert.eq(Platform.defaultMode("wsl"), "builtin")
Assert.eq(Platform.defaultMode("kindle"), "builtin")
Assert.eq(Platform.defaultMode("kobo"), "builtin")
Assert.eq(Platform.defaultMode("pocketbook"), "builtin")
Assert.eq(Platform.defaultMode(nil), "builtin")

-- 后端选择：Android 用 system_ime，桌面 / WSL 用 system_text，墨水屏没有后端
Assert.eq(Platform.backend("android"), "features.system_ime")
Assert.eq(Platform.backend("windows"), "features.system_text")
Assert.eq(Platform.backend("macos"), "features.system_text")
Assert.eq(Platform.backend("linux"), "features.system_text")
Assert.eq(Platform.backend("wsl"), "features.system_text")
Assert.is_nil(Platform.backend("kindle"))
Assert.is_nil(Platform.backend("kobo"))
Assert.is_nil(Platform.backend("pocketbook"))
Assert.is_nil(Platform.backend(nil))
