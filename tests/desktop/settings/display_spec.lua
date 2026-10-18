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
require("support.theme_stubs").install()
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
package.preload["utils.settings"] = function()
    return { get = function() return { mesh_mask = true } end }
end
_G.G_reader_settings = {
    isTrue = function() return false end,
    saveSetting = function() end,
}

package.loaded["desktop.pages.setting.display"] = nil
local Display = require("desktop.pages.setting.display")
local rows = Display:appearanceRows{ desktop = {}, font_name = "Noto", scale = 120 }
local screen = Display:screenRows{ desktop = {} }
Assert.eq(rows[1](600).title, "界面风格")
Assert.eq(rows[1](600).status, "纸本")
Assert.eq(rows[2](600).title, "界面字体")
Assert.eq(rows[3](600).title, "界面缩放")
Assert.eq(rows[4](600).title, "背景遮罩")
Assert.is_true(rows[4](600).toggle)
Assert.len(rows, 4, "夜间与亮度不在外观分节")
Assert.eq(screen[1](600).title, "屏幕刷新")
Assert.eq(screen[1](600).status, "每 6 页")
Assert.eq(screen[2](600).title, "彩色屏幕支持")
Assert.is_false(screen[2](600).toggle)

eink, color_screen, frontlight = false, false, false
package.loaded["device"] = nil
package.loaded["desktop.pages.setting.display"] = nil
Display = require("desktop.pages.setting.display")
Assert.eq(#Display:screenRows{ desktop = {} }, 0, "无墨水屏/彩屏时不展示刷新与彩色项")
