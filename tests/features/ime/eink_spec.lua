--[[--
features.ime 墨水屏不变量的真实路径回归：不 stub 平台判定，只提供假 Device，
让 features.ime.platform 的真实 isEink / isEinkCurrent 参与 inputMode()。

@module tests.features.ime.eink_spec
--]]

local Assert = require("support.assert")

-- ── 配置 ─────────────────────────────────────────────
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

_G.G_reader_settings = {
    readSetting = function(_, _key, default) return default end,
    saveSetting = function() end,
    delSetting = function() end,
}

-- ── 真实 features.ime.platform 读这个假 device ────────
local eink_device = false
package.preload["device"] = function()
    return {
        hasEinkScreen = function() return eink_device end,
    }
end

-- ── 其余重依赖用轻量替身 ─────────────────────────────
package.preload["features.ime.registry"] = function()
    local method = { id = "pinyin", label = "拼音", dictionary = "pinyin" }
    return {
        current = function() return method end,
        get = function() return method end,
        list = function() return { method } end,
        isAvailable = function() return true end,
        fileExists = function() return true end,
        entries = function() return "100" end,
        builtAt = function() return "2026-08-19" end,
    }
end
package.preload["features.ime.hide_key"] = function() return { onCreate = function() end } end
package.preload["features.ime.candidate_bar"] = function()
    return { install = function() end, reset = function() end, activate = function() end }
end
package.preload["features.ime.convert"] = function() return { DIRS = {} } end

local Platform = require("features.ime.platform")
local IME = require("features.ime")

-- ── 墨水屏：真实 Device:hasEinkScreen() 为真时强制 builtin ──
eink_device = true
owners["features.ime"] = { input_mode = "system" }
Assert.is_true(Platform.isEinkCurrent(), "真实路径必须认出墨水屏")
Assert.eq(IME.inputMode(), "builtin", "墨水屏忽略显式 system")
Assert.eq(owners["features.ime"].input_mode, "system", "只忽略存储值，不覆盖用户选择")

-- 未设置时迁移写 resolved mode：墨水屏解析为 builtin
eink_device = true
owners["features.ime"] = {}
owners["features.system_ime"] = { enabled = true }
save_calls = {}
Assert.eq(IME.inputMode(), "builtin", "墨水屏 + 旧开关开启仍是 builtin")
Assert.eq(owners["features.ime"].input_mode, "builtin", "迁移写 resolved mode")
Assert.contains(save_calls, "features.ime")

-- ── 非墨水屏：显式 system 保留 ────────────────────────
eink_device = false
owners["features.ime"] = { input_mode = "system" }
Assert.is_false(Platform.isEinkCurrent())
Assert.eq(IME.inputMode(), "system", "非墨水屏保留显式 system")
