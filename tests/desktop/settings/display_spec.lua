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
package.preload["device"] = function()
    return {
        hasEinkScreen = function() return eink end,
        hasFrontlight = function() return frontlight end,
        hasColorScreen = function() return color_screen end,
        isKobo = function() return false end,
        screen = {
            isColorScreen = function() return color_screen end,
            isColorEnabled = function() return false end,
        },
    }
end
package.preload["ui/uimanager"] = function()
    return {
        getRefreshRate = function() return 6, 6 end,
        setRefreshRate = function() end,
        broadcastEvent = function() end,
        show = function() end,
        askForRestart = function() end,
    }
end
local settings, saved = { mesh_mask = true, swipe_dismiss = "off" }, 0
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() saved = saved + 1 end }
end
_G.G_reader_settings = {
    isTrue = function() return false end,
    saveSetting = function() end,
}

package.loaded["desktop.pages.setting.display"] = nil
local Display = require("desktop.pages.setting.display")
local redraws = 0
local rows = Display:appearanceRows{ desktop = { updateView = function() redraws = redraws + 1 end }, font_name = "Noto", scale = 120 }
local screen = Display:screenRows{ desktop = {} }
Assert.eq(rows[1](600).title, "界面风格")
Assert.eq(rows[1](600).status, "纸本")
Assert.eq(rows[2](600).title, "界面字体")
Assert.eq(rows[3](600).title, "字体加粗")
Assert.eq(rows[4](600).title, "界面缩放")
Assert.eq(rows[5](600).title, "背景遮罩")
Assert.is_true(rows[5](600).toggle)
Assert.eq(rows[6](600).title, "弹窗关闭手势")
Assert.eq(rows[6](600).status, "关闭")
Assert.len(rows, 8, "夜间与亮度不在外观分节")
Assert.eq(rows[7](600).title, "底部导航名称")
Assert.is_true(rows[7](600).toggle, "旧配置默认显示名称")
rows[7](600).callback()
Assert.is_false(settings.tabbar_labels)
Assert.is_false(rows[7](600).toggle)
Assert.eq(saved, 1)
Assert.eq(redraws, 1)
rows[7](600).callback()
Assert.is_true(settings.tabbar_labels)
Assert.eq(rows[8](600).title, "主题色")
Assert.eq(rows[8](600).status, "蓝色")
rows[8](600).callback()
local picker = Themed.last("list")
Assert.eq(picker.current, 0x0756AD)
Themed.choose(picker, 3)
Assert.eq(settings.theme_color, 0x7038A0)
Assert.eq(rows[8](600).status, "紫色")
Assert.eq(redraws, 3, "切换颜色立即重建界面")
Assert.eq(screen[1](600).title, "屏幕刷新")
Assert.eq(screen[1](600).status, "每 6 页")
Assert.eq(screen[2](600).title, "彩色屏幕支持")
Assert.is_false(screen[2](600).toggle)

eink, color_screen, frontlight = false, false, false
package.loaded["device"] = nil
package.loaded["desktop.pages.setting.display"] = nil
Display = require("desktop.pages.setting.display")
Assert.eq(#Display:screenRows{ desktop = {} }, 0, "无墨水屏/彩屏时不展示刷新与彩色项")
