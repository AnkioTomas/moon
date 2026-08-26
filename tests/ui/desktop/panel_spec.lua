--[[--
ui.desktop.panel 离线用例：快捷动作配置、能力过滤与灯光范围换算。

@module tests.ui.desktop.panel_spec
--]]

local Assert = require("support.assert")

local settings = { quick_panel_actions = { "night", "wifi" } }
local saved = 0
package.preload["utils.settings"] = function()
    return {
        get = function() return settings end,
        save = function() saved = saved + 1 end,
    }
end

package.preload["l10n"] = function()
    return { apply = function() end }
end
package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["logger"] = function()
    return { err = function() end }
end

local powerd = {
    fl_min = 0,
    fl_max = 24,
    fl_warmth_min = 0,
    fl_warmth_max = 24,
    intensity = 6,
    warmth = 25,
}
function powerd:frontlightIntensity() return self.intensity end
function powerd:setIntensity(value) self.intensity = value end
function powerd:turnOffFrontlight() self.intensity = 0 end
function powerd:updateResumeFrontlightState() self.resume_updated = true end
function powerd:frontlightWarmth() return self.warmth end
function powerd:toNativeWarmth(value) return value * 24 / 100 end
function powerd:fromNativeWarmth(value) return value * 100 / 24 end
function powerd:setWarmth(value) self.warmth = value end

local has_frontlight = true
local has_natural_light = true
local can_suspend = true
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        },
        hasWifiToggle = function() return true end,
        hasFrontlight = function() return has_frontlight end,
        hasNaturalLight = function() return has_natural_light end,
        canSuspend = function() return can_suspend end,
        getPowerDevice = function() return powerd end,
    }
end

local events = {}
local next_ticks = {}
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        broadcastEvent = function(_, event) events[#events + 1] = event.name end,
        nextTick = function(_, fn) next_ticks[#next_ticks + 1] = fn end,
        scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = { delay = delay, fn = fn } end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/network/manager"] = function()
    return { isWifiOn = function() return false end }
end

G_reader_settings = {
    isTrue = function(_, key) return key == "night_mode" end,
}

local Panel = require("ui.panel.desktop")

-- 默认夜间模式与 Wi-Fi；未知动作不写入配置。
Assert.eq(Panel.enabledCount(), 2)
Panel.setEnabled("missing", true)
Assert.eq(saved, 0)

-- 灯光百分比与图标解析集中到 panel，两个入口复用同一份结果。
Assert.eq(Panel.lightPercent("brightness"), 25)
Assert.eq(Panel.lightPercent("warmth"), 25)
local initial_menu = Panel.menuActions()
Assert.eq(initial_menu[1].id, "night")
Assert.eq(initial_menu[1].icon, "dark_mode")
Assert.eq(initial_menu[2].id, "wifi")
Assert.eq(initial_menu[2].icon, "signal_wifi_4_bar")

-- 滑杆按设备能力生成，并携带显示百分比。
local sliders = Panel.sliders()
Assert.len(sliders, 2)
Assert.eq(sliders[1].kind, "brightness")
Assert.eq(sliders[1].value, 25)
Assert.eq(sliders[2].kind, "warmth")
Assert.eq(sliders[2].value, 25)

-- 暖色本身已是 0..100，避免原生刻度往返在非整倍值上丢精度。
powerd.warmth = 10
Assert.eq(Panel.lightPercent("warmth"), 10)

-- 启用顺序、去重与移动。
settings.quick_panel_actions = {}
Panel.setEnabled("rotate", true)
Panel.setEnabled("refresh", true)
Panel.setEnabled("rotate", true)
Assert.eq(Panel.enabledCount(), 2)
Assert.eq(settings.quick_panel_actions[1], "rotate")
Panel.move("refresh", -1)
Assert.eq(settings.quick_panel_actions[1], "refresh")
Assert.eq(settings.quick_panel_actions[2], "rotate")
Panel.setEnabled("refresh", false)
Assert.eq(Panel.enabledCount(), 1)
Assert.eq(settings.quick_panel_actions[1], "rotate")

-- 不支持的动作仍可配置，但运行时从可见项过滤。
Panel.setEnabled("night", true)
Panel.setEnabled("wifi", true)
Panel.setEnabled("frontlight", true)
Panel.setEnabled("suspend", true)
has_frontlight = false
can_suspend = false
local visible = {}
for _, action in ipairs(Panel.menuActions()) do
    visible[#visible + 1] = action.id
end
Assert.contains(visible, "night")
Assert.contains(visible, "wifi")
Assert.contains(visible, "rotate")
Assert.is_true(not table.concat(visible, ","):find("frontlight", 1, true))
Assert.is_true(not table.concat(visible, ","):find("suspend", 1, true))

-- 夜间模式走 KOReader 事件，不直接改全局设置。
Assert.is_true(Panel.executeAction("night", { refresh = function() end }))
Assert.eq(events[1], "ToggleNightMode")
Assert.eq(#next_ticks, 1)

-- 原生顶部面板已移除；Wi-Fi 保留菜单并延迟刷新：设备状态回填需要时间，延迟不能是硬编码魔法分支。
local wifi_closed = 0
Assert.is_true(Panel.executeAction("wifi", {
    close = function() wifi_closed = wifi_closed + 1 end,
    refresh = function() end,
}))
Assert.eq(wifi_closed, 0)
Assert.eq(events[2], "ToggleWifi")
Assert.eq(scheduled[#scheduled].delay, 1)

-- 亮度百分比映射到设备原生 0..24；暖度同样先转原生范围。
has_frontlight = true
Assert.is_true(Panel.setLevel("brightness", 0.5))
Assert.eq(powerd.intensity, 12)
Assert.is_true(powerd.resume_updated)
Assert.is_true(Panel.setLevel("warmth", 0.75))
Assert.eq(powerd.warmth, 75)

-- 亮度滑到最左端关闭前光。
Assert.is_true(Panel.setLevel("brightness", 0))
Assert.eq(powerd.intensity, 0)
