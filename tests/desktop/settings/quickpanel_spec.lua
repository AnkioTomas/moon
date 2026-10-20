--[[-- 快捷面板设置项离线用例。
@module tests.desktop.pages.setting.quickpanel_spec
--]]

local Assert = require("support.assert")

local Themed = require("support.theme_stubs")
Themed.install()

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function()
    return function(value) return value end
end

local built
package.preload["ui.themes.widgets.row"] = function()
    return {
        widget = function(opts)
            built = opts
            return opts
        end,
    }
end
package.preload["features.panel.desktop"] = function()
    return {
        options = function()
            return {
                {
                    id = "night",
                    scope = "desktop",
                    title = "夜间模式",
                    icon = "dark_mode",
                    enabled = true,
                    position = 1,
                    available = true,
                },
                {
                    id = "suspend",
                    scope = "desktop",
                    title = "休眠",
                    icon = "mode_standby",
                    enabled = false,
                    position = nil,
                    available = false,
                },
            }
        end,
        enabledCount = function() return 1 end,
        setEnabled = function() end,
        move = function() end,
    }
end
package.preload["features.panel.reader"] = function()
    return {
        options = function()
            return {{
                id = "toc",
                scope = "reader",
                title = "目录",
                icon = "menu_book",
                enabled = true,
                position = 1,
                available = true,
            }}
        end,
        enabledCount = function() return 1 end,
        setEnabled = function() end,
        move = function() end,
    }
end
package.preload["ffi/util"] = function()
    return { template = function(value, position) return value:gsub("%%1", tostring(position)) end }
end

local lights = { hasNaturalLight = false, hasFrontlight = false }
package.preload["device"] = function()
    return {
        hasNaturalLight = function() return lights.hasNaturalLight end,
        hasFrontlight = function() return lights.hasFrontlight end,
    }
end
local panel_settings = { quick_panel_warmth = true, quick_panel_brightness = true }
local panel_saved = 0
package.preload["utils.settings"] = function()
    return {
        get = function() return panel_settings end,
        save = function() panel_saved = panel_saved + 1 end,
    }
end

local QuickPanel = require("features.panel.settings")
local desktop = { updateView = function() end }
local desktop_rows = QuickPanel.rows("desktop", desktop)
local reader_rows = QuickPanel.rows("reader", desktop)

Assert.len(desktop_rows, 2)
Assert.len(reader_rows, 1)

-- 有前光 / 色温的设备多出两个滑块开关，点一下翻转并落盘。
lights.hasNaturalLight, lights.hasFrontlight = true, true
local with_toggles = QuickPanel.rows("desktop", desktop)
Assert.len(with_toggles, 4)
Assert.len(QuickPanel.rows("reader", desktop), 1)
with_toggles[1](400)
Assert.eq(built.title, "亮度滑块")
built.callback()
Assert.eq(panel_settings.quick_panel_brightness, false)
Assert.eq(panel_saved, 1)
with_toggles[2](400)
Assert.eq(built.title, "冷暖色调滑块")
lights.hasNaturalLight, lights.hasFrontlight = false, false

-- 桌面动作与其他动作一样可配置。
desktop_rows[1](400)
Assert.eq(built.title, "夜间模式")
Assert.eq(built.status, "第 1 位")
Assert.is_true(built.chevron)
Assert.is_true(type(built.callback) == "function")
built.callback()
local captured_dialog = Themed.last("sheet")
Assert.not_nil(captured_dialog)
Assert.eq(#captured_dialog.items, 5)
Assert.eq(captured_dialog.items[1].text, "停用")
Assert.eq(captured_dialog.items[2].text, "上移")
Assert.is_false(captured_dialog.items[2].enabled, "第 1 位不能上移")
Assert.eq(captured_dialog.items[3].text, "下移")
Assert.eq(captured_dialog.items[4].text, "设为第几位…")
Assert.is_false(captured_dialog.items[4].enabled, "只有 1 项时无从排序")
Assert.eq(captured_dialog.items[5].text, "关闭")

desktop_rows[2](400)
Assert.eq(built.title, "休眠")
Assert.eq(built.status, "当前设备不可用")
Assert.is_false(built.chevron)
Assert.is_nil(built.callback)

-- 阅读页动作走同一套配置流程。
reader_rows[1](400)
Assert.eq(built.title, "目录")
Assert.eq(built.status, "第 1 位")
Assert.is_true(built.chevron)

Assert.eq(QuickPanel.enabledCount("desktop"), 1)
Assert.eq(QuickPanel.enabledCount("reader"), 1)
