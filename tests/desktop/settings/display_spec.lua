--[[-- 显示设置：字体缩放 + 屏幕刷新/彩色渲染条件行。 --]]

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
local night_window
package.preload["utils.settings"] = function()
    return {
        get = function() return { mesh_mask = true } end,
        feature = function(name)
            assert(name == "nightmode")
            return { auto_night = night_window and "schedule" or "off", auto_light = false }
        end,
    }
end
package.preload["features.nightmode"] = function()
    return {
        window = function() if night_window then return night_window[1], night_window[2] end end,
        hasSensor = function() return false end,
    }
end
_G.G_reader_settings = {
    isTrue = function() return false end,
    saveSetting = function() end,
}

package.loaded["desktop.pages.setting.display"] = nil
local Display = require("desktop.pages.setting.display")
local rows = Display:rows{
    desktop = {}, font_name = "Noto", scale = 120, grid_max_cols = 4,
}
Assert.eq(rows[1](600).title, "界面风格")
Assert.eq(rows[1](600).status, "纸本")
Assert.eq(rows[2](600).title, "界面字体")
Assert.eq(rows[3](600).title, "界面缩放")
Assert.eq(rows[4](600).title, "书架每行数量")
Assert.eq(rows[5](600).title, "背景遮罩")
Assert.eq(rows[5](600).status, "开")
Assert.is_true(rows[5](600).status_on)
Assert.eq(rows[6](600).title, "自动夜间模式")
Assert.eq(rows[6](600).status, "关")
Assert.is_false(rows[6](600).status_on)
night_window = { 22 * 60, 7 * 60 }
Assert.eq(rows[6](600).status, "22:00–07:00")
Assert.is_true(rows[6](600).status_on)
Assert.eq(rows[7](600).title, "自动亮度")
Assert.eq(rows[7](600).status, "关")
Assert.is_false(rows[7](600).status_on)
Assert.eq(rows[7](600).subtitle, "按时段和天气调节；手动调亮度会关闭自动亮度")
Assert.eq(rows[8](600).title, "屏幕刷新")
Assert.eq(rows[8](600).status, "每 6 页")
Assert.eq(rows[9](600).title, "彩色屏幕支持")
Assert.is_false(rows[9](600).status_on)

eink, color_screen, frontlight = false, false, false
package.loaded["device"] = nil
package.loaded["desktop.pages.setting.display"] = nil
Display = require("desktop.pages.setting.display")
rows = Display:rows{
    desktop = {}, font_name = "Noto", scale = 120, grid_max_cols = 4,
}
Assert.eq(#rows, 6, "无墨水屏/彩屏/前光时不展示刷新、彩色与自动亮度项")
