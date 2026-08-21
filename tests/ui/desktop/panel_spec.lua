--[[--
ui.desktop.panel 离线用例：快捷动作配置、能力过滤与灯光范围换算。

@module tests.ui.desktop.panel_spec
--]]

local Assert = require("support.assert")

local settings = { quick_panel_actions = {} }
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
package.preload["ffi/blitbuffer"] = function()
    return setmetatable({}, { __index = function() return 0 end })
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
package.preload["ui/uimanager"] = function()
    return {
        broadcastEvent = function(_, event) events[#events + 1] = event.name end,
        nextTick = function(_, fn) next_ticks[#next_ticks + 1] = fn end,
        scheduleIn = function(_, _delay, fn) next_ticks[#next_ticks + 1] = fn end,
        close = function() end,
        setDirty = function() end,
    }
end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/network/manager"] = function()
    return { isWifiOn = function() return false end }
end

local function classStub()
    local C = {}
    C.__index = C
    function C:new(o) return setmetatable(o or {}, self) end
    function C:extend(o)
        o = o or {}
        o.__index = o
        return setmetatable(o, { __index = self })
    end
    return C
end

package.preload["ui/widget/container/inputcontainer"] = classStub
for _, name in ipairs({
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/overlapgroup",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/linewidget",
    "ui/widget/progresswidget",
    "ui/widget/textwidget",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}) do
    package.preload[name] = classStub
end
package.preload["ui/geometry"] = function()
    local Geom = classStub()
    return Geom
end
package.preload["ui/gesturerange"] = classStub
package.preload["ui.components.icon"] = function()
    return { widget = function() return {} end }
end
package.preload["ui.components.bookui"] = function()
    return {
        sz = function(n) return n end,
        line = function() return 1 end,
        pagePad = function() return 16 end,
        face = function() return {} end,
        rule = function() return 1 end,
        track = function() return 1 end,
        surface = function() return 1 end,
        actionSurface = function() return 1 end,
        pillRadius = function(h) return math.floor(h / 2) end,
        progressBar = function(width, height, percent)
            return { width = width, height = height, percentage = percent }
        end,
    }
end

G_reader_settings = {
    isTrue = function(_, key) return key == "night_mode" end,
}

local Panel = require("ui.desktop.panel")

-- 默认仅固定动作；配置接口不写入未知动作。
Assert.eq(Panel.enabledCount(), 0)
Panel.setEnabled("missing", true)
Assert.eq(saved, 0)

-- 第三方动作必须使用稳定 id 注册，并能复用快捷面板配置。
local callback_count = 0
local ok, err = Panel.registerAction{
    id = "plugin.example.popup",
    title = "插件页面",
    icon = "extension",
    callback = function() callback_count = callback_count + 1 end,
}
Assert.is_true(ok)
Assert.is_nil(err)
local duplicate_ok = Panel.registerAction{
    id = "plugin.example.popup",
    title = "重复动作",
    icon = "extension",
    callback = function() end,
}
Assert.is_true(not duplicate_ok)
Panel.setEnabled("plugin.example.popup", true)
local plugin_option
for _, option in ipairs(Panel.options()) do
    if option.id == "plugin.example.popup" then plugin_option = option break end
end
Assert.is_true(plugin_option ~= nil)
Assert.is_true(plugin_option.enabled)
Assert.eq(plugin_option.icon, "extension")
local visible_with_plugin = setmetatable({}, { __index = Panel }):visibleActionIds()
Assert.contains(visible_with_plugin, "plugin.example.popup")
Panel.setEnabled("plugin.example.popup", false)

-- 启用顺序、去重与移动。
Panel.setEnabled("rotate", true)
Panel.setEnabled("refresh", true)
Panel.setEnabled("rotate", true)
Assert.eq(Panel.enabledCount(), 2)
Assert.eq(settings.quick_panel_actions[1], "rotate")

Panel.setIcon("plugin.example.popup", "settings")
Assert.eq(settings.quick_panel_icons["plugin.example.popup"], "settings")
local plugin_icon_option
for _, option in ipairs(Panel.options()) do
    if option.id == "plugin.example.popup" then plugin_icon_option = option break end
end
Assert.eq(plugin_icon_option.icon, "settings")

local instance_for_plugin = setmetatable({}, { __index = Panel })
instance_for_plugin._closed = false
instance_for_plugin:runAction("plugin.example.popup")
Assert.eq(callback_count, 1)
Assert.is_true(instance_for_plugin._closed)
Assert.is_true(Panel.unregisterAction("plugin.example.popup"))
Assert.is_true(not Panel.unregisterAction("plugin.example.popup"))
Assert.eq(settings.quick_panel_actions[2], "refresh")
Panel.move("refresh", -1)
Assert.eq(settings.quick_panel_actions[1], "refresh")
Assert.eq(settings.quick_panel_actions[2], "rotate")
Panel.setEnabled("refresh", false)
Assert.eq(Panel.enabledCount(), 1)
Assert.eq(settings.quick_panel_actions[1], "rotate")

-- 不支持的动作仍可配置，但运行时从可见项过滤。
Panel.setEnabled("frontlight", true)
Panel.setEnabled("suspend", true)
has_frontlight = false
can_suspend = false
local instance = setmetatable({}, { __index = Panel })
local visible = instance:visibleActionIds()
Assert.contains(visible, "night")
Assert.contains(visible, "wifi")
Assert.contains(visible, "rotate")
Assert.is_true(not table.concat(visible, ","):find("frontlight", 1, true))
Assert.is_true(not table.concat(visible, ","):find("suspend", 1, true))

-- 夜间模式走 KOReader 事件，不直接改全局设置。
instance._closed = false
instance:runAction("night")
Assert.eq(events[1], "ToggleNightMode")
Assert.eq(#next_ticks, 1)

-- 原生顶部面板关闭快捷面板后广播 KOReader 的 ShowMenu 事件。
instance:runAction("native_menu")
Assert.is_true(instance._closed)
Assert.eq(events[2], "ShowMenu")

-- 亮度百分比映射到设备原生 0..24；暖度同样先转原生范围。
has_frontlight = true
instance._slider_rects = {
    brightness = { x = 0, y = 0, w = 100, h = 20 },
    warmth = { x = 0, y = 30, w = 100, h = 20 },
}
instance._last_slider_refresh = os.clock()
Assert.is_true(instance:setSlider("brightness", { x = 50, y = 10 }, false))
Assert.eq(powerd.intensity, 12)
Assert.is_true(powerd.resume_updated)
Assert.is_true(instance:setSlider("warmth", { x = 75, y = 40 }, false))
Assert.eq(powerd.warmth, 75)

-- 亮度滑到最左端关闭前光。
Assert.is_true(instance:setSlider("brightness", { x = 0, y = 10 }, false))
Assert.eq(powerd.intensity, 0)
