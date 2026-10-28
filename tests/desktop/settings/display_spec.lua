--[[-- 外观（风格/字体/缩放）+ 屏幕刷新/彩色渲染条件行；夜间与亮度在 nightmode feature。 --]]

local Assert = require("support.assert")

package.preload["gettext"] = function() return function(text) return text end end
package.preload["ffi/util"] = function()
    return { template = function(text, value) return (text:gsub("%%1", tostring(value))) end }
end
package.preload["ui.themes.widgets.row"] = function()
    return { widget = function(opts) return opts end }
end
package.preload["ui.widgets.fontpicker"] = function() return { open = function() end } end
local Themed = require("support.theme_stubs")
Themed.install()
package.preload["ui.themes"] = function()
    return {
        id = function() return "paper" end,
        ids = { "paper", "bold", "soft" },
        scale = function() return 120 end,
        SCALE_MIN = 100,
        SCALE_MAX = 180,
        SCALE_STEP = 10,
        setScale = function(n) return n end,
    }
end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o end } end
package.preload["ui/event"] = function() return { new = function(_, name) return { name = name } end } end

local eink, color_screen, frontlight = true, true, true
local color_enabled = false
local canvas_color, color_events = nil, 0
package.preload["device"] = function()
    return {
        hasEinkScreen = function() return eink end,
        hasFrontlight = function() return frontlight end,
        hasColorScreen = function() return color_screen end,
        isKobo = function() return false end,
        screen = {
            isColorScreen = function() return color_screen end,
            isColorEnabled = function() return color_enabled end,
        },
    }
end
package.preload["ui/uimanager"] = function()
    return {
        getRefreshRate = function() return 6, 6 end,
        setRefreshRate = function() end,
        broadcastEvent = function(_, event)
            Assert.eq(event.name, "ColorRenderingUpdate")
            color_events = color_events + 1
        end,
        show = function() end,
        askForRestart = function() end,
    }
end
local settings, saved = { mesh_mask = true, swipe_dismiss = "off" }, 0
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() saved = saved + 1 end }
end
_G.G_reader_settings = {
    isTrue = function() return color_enabled end,
    saveSetting = function(_, key, value)
        Assert.eq(key, "color_rendering")
        color_enabled = value
    end,
}
package.preload["document/canvascontext"] = function()
    return { setColorRenderingEnabled = function(_, value) canvas_color = value end }
end

package.loaded["desktop.pages.setting.display"] = nil
local Display = require("desktop.pages.setting.display")
local redraws = 0
local ctx = { desktop = { updateView = function() redraws = redraws + 1 end }, font_name = "Noto", scale = 120 }
local rows = Display:appearanceRows(ctx)
local screen = Display:screenRows{ desktop = {} }
Assert.eq(rows[1](600).title, "界面风格")
Assert.eq(rows[1](600).status, "纸本")
Assert.eq(rows[2](600).title, "界面字体")
Assert.eq(rows[3](600).title, "字体加粗")
Assert.eq(rows[4](600).title, "界面缩放")
Assert.eq(rows[5](600).title, "背景遮罩")
Assert.is_true(rows[5](600).toggle)
Assert.len(rows, 7, "夜间与亮度、弹窗关闭手势不在外观分节")
Assert.eq(rows[6](600).title, "底部导航名称")
Assert.is_true(rows[6](600).toggle, "旧配置默认显示名称")
rows[6](600).callback()
Assert.is_false(settings.tabbar_labels)
Assert.is_false(rows[6](600).toggle)
Assert.eq(saved, 1)
Assert.eq(redraws, 1)
rows[6](600).callback()
Assert.is_true(settings.tabbar_labels)
Assert.eq(rows[7](600).title, "彩色显示")
Assert.is_false(rows[7](600).toggle)
Assert.is_nil(rows[8], "彩色关闭时隐藏主题色")
rows[7](600).callback()
Assert.is_true(canvas_color)
Assert.eq(color_events, 1)
rows = Display:appearanceRows(ctx)
Assert.len(rows, 8)
Assert.eq(rows[8](600).title, "主题色")
Assert.eq(rows[8](600).status, "#0756AD", "没选过色板时显示旧单色值")
rows[8](600).callback()
local picker = Themed.last("list")
Assert.is_nil(picker.current)
Assert.eq(picker.items[3].text, "赤陶红")
Themed.choose(picker, 3)
Assert.eq(settings.theme_preset, "clay")
Assert.is_nil(settings.theme_color, "只写 theme_preset，不再回写旧单色键")
Assert.eq(rows[8](600).status, "赤陶红")
Assert.eq(redraws, 4, "开彩色和切换颜色立即重建界面")
Assert.eq(screen[1](600).title, "屏幕刷新")
Assert.eq(screen[1](600).status, "每 6 页")
Assert.len(screen, 1, "彩色开关不再放在屏幕分节")
rows[7](600).callback()
Assert.is_false(canvas_color)
Assert.eq(color_events, 2)
rows = Display:appearanceRows(ctx)
Assert.len(rows, 7, "关彩色后主题色消失")
Assert.eq(settings.theme_preset, "clay", "隐藏主题色不清除已有选择")
rows[7](600).callback()
rows = Display:appearanceRows(ctx)
Assert.eq(rows[8](600).status, "赤陶红", "重新开启沿用已选色板")
rows[7](600).callback()

eink, color_screen, frontlight = false, false, false
package.loaded["device"] = nil
package.loaded["desktop.pages.setting.display"] = nil
Display = require("desktop.pages.setting.display")
Assert.eq(#Display:screenRows{ desktop = {} }, 0, "无墨水屏/彩屏时不展示刷新与彩色项")
Assert.len(Display:appearanceRows(ctx), 6, "不支持彩色时不展示彩色开关和主题色")
require("device").screen.isColorEnabled = nil
Assert.len(Display:appearanceRows(ctx), 6, "缺少彩色查询接口不会报错")

Assert.is_nil(rawget(Display, "inputRows"), "分页与弹窗不属于外观设置")
