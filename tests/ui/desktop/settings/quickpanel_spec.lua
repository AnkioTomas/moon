--[[-- 快捷面板设置项离线用例。
@module tests.ui.desktop.settings.quickpanel_spec
--]]

local Assert = require("support.assert")

local captured_dialog
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, value) captured_dialog = value return value end }
end
package.preload["ui/uimanager"] = function()
    return { show = function() end, close = function() end }
end
package.preload["ui.components.popup"] = function()
    return { list = function() end }
end

package.preload["l10n"] = function() return { apply = function() end } end
package.preload["gettext"] = function()
    return function(value) return value end
end

local built
package.preload["ui.components.settingrow"] = function()
    return {
        build = function(_width, value)
            built = value
            return value
        end,
    }
end
package.preload["ui.panel.desktop"] = function()
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
package.preload["ui.panel.reader"] = function()
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

local QuickPanel = require("ui.desktop.settings.quickpanel")
local desktop = { rebuild = function() end }
local sections = QuickPanel.sections(desktop)

Assert.len(sections, 2)
Assert.eq(sections[1].title, "桌面")
Assert.eq(sections[2].title, "阅读")
Assert.len(sections[1].rows, 2)
Assert.len(sections[2].rows, 1)

-- 桌面动作与其他动作一样可配置。
sections[1].rows[1](400)
Assert.eq(built.title, "夜间模式")
Assert.eq(built.status, "第 1 位")
Assert.is_true(built.chevron)
Assert.is_true(type(built.callback) == "function")
built.callback()
Assert.not_nil(captured_dialog)
Assert.eq(#captured_dialog.buttons, 3)
Assert.eq(captured_dialog.buttons[1][1].text, "停用")
Assert.eq(captured_dialog.buttons[2][1].text, "上移")
Assert.eq(captured_dialog.buttons[2][2].text, "下移")
Assert.eq(captured_dialog.buttons[3][1].text, "关闭")

sections[1].rows[2](400)
Assert.eq(built.title, "休眠")
Assert.eq(built.status, "当前设备不可用")
Assert.is_true(built.chevron)

-- 阅读页动作走同一套配置流程。
sections[2].rows[1](400)
Assert.eq(built.title, "目录")
Assert.eq(built.status, "第 1 位")
Assert.is_true(built.chevron)

Assert.eq(QuickPanel.enabledCount(), 2)
