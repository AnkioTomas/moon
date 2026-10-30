--[[-- 外观（风格/字体/缩放/彩色分节）+ 屏幕刷新；夜间与亮度在 nightmode feature。 --]]

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
local refresh_on_images = true
package.preload["ui/uimanager"] = function()
    return {
        getRefreshRate = function() return 6, 6 end,
        setRefreshRate = function() end,
        broadcastEvent = function(_, event)
            if event.name == "ToggleFlashOnPagesWithImages" then
                refresh_on_images = not refresh_on_images
                return
            end
            Assert.eq(event.name, "ColorRenderingUpdate")
            color_events = color_events + 1
        end,
        show = function() end,
        askForRestart = function() end,
    }
end
local settings, saved = { mesh_mask = true, swipe_dismiss = "off", color_saturation = "standard" }, 0
package.preload["utils.settings"] = function()
    return { get = function() return settings end, save = function() saved = saved + 1 end }
end
_G.G_reader_settings = {
    isTrue = function() return color_enabled end,
    nilOrTrue = function(_, key)
        Assert.eq(key, "refresh_on_pages_with_images")
        return refresh_on_images
    end,
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

---@param sections table[]
---@return table[] titles, table[][] rows_by_section
local function flatten(sections)
    local titles, rows = {}, {}
    for i, section in ipairs(sections) do
        titles[i] = section.title
        rows[i] = {}
        for _, build in ipairs(section.rows) do rows[i][#rows[i] + 1] = build(600) end
    end
    return titles, rows
end

local titles, rows = flatten(Display:appearanceSections(ctx))
Assert.eq(table.concat(titles, ","), "风格,字体与缩放,彩色")
Assert.eq(rows[1][1].title, "界面风格")
Assert.eq(rows[1][1].status, "纸本")
Assert.len(rows[1], 2, "底部导航名称已挪到桌面分组")
Assert.eq(rows[1][2].title, "背景遮罩")
Assert.is_true(rows[1][2].toggle)
Assert.eq(rows[2][1].title, "界面字体")
Assert.eq(rows[2][2].title, "字体加粗")
Assert.eq(rows[2][3].title, "界面缩放")
Assert.len(rows[3], 1, "彩色关闭时只有开关")
Assert.eq(rows[3][1].title, "彩色显示")
Assert.is_false(rows[3][1].toggle)

rows[3][1].callback()
Assert.is_true(canvas_color)
Assert.eq(color_events, 1)
titles, rows = flatten(Display:appearanceSections(ctx))
Assert.len(rows[3], 3, "开彩色后出主题色与饱和度")
Assert.eq(rows[3][2].title, "主题色")
Assert.eq(rows[3][2].status, "#0756AD", "没选过色板时显示旧单色值")
Assert.eq(rows[3][3].title, "色彩饱和度")
Assert.eq(rows[3][3].status, "标准")
rows[3][2].callback()
local picker = Themed.last("list")
Assert.is_nil(picker.current)
Assert.eq(picker.items[1].text, "墨黑")
Assert.eq(picker.items[4].text, "赤陶红")
Themed.choose(picker, 4)
Assert.eq(settings.theme_preset, "clay")
Assert.is_nil(settings.theme_color, "只写 theme_preset，不再回写旧单色键")
titles, rows = flatten(Display:appearanceSections(ctx))
Assert.eq(rows[3][2].status, "赤陶红")
rows[3][3].callback()
local sat = Themed.last("list")
Assert.eq(sat.current, "standard")
Assert.eq(sat.items[4].text, "极致")
Themed.choose(sat, 4)
Assert.eq(settings.color_saturation, "max")
titles, rows = flatten(Display:appearanceSections(ctx))
Assert.eq(rows[3][3].status, "极致")

local screen_desk = { updateView = function() redraws = redraws + 1 end }
local screen = Display:screenRows{ desktop = screen_desk }
Assert.len(screen, 2, "墨水屏：刷新间隔 + 遇到图片刷新")
Assert.eq(screen[1](600).title, "屏幕刷新")
Assert.eq(screen[1](600).status, "每 6 页")
Assert.eq(screen[2](600).title, "遇到图片刷新")
Assert.is_true(screen[2](600).toggle, "原生默认开")
local before = redraws
screen[2](600).callback()
Assert.is_false(refresh_on_images)
Assert.eq(redraws, before + 1)
Assert.is_false(Display:screenRows{ desktop = screen_desk }[2](600).toggle)
rows[3][1].callback()
Assert.is_false(canvas_color)
Assert.eq(color_events, 2)
titles, rows = flatten(Display:appearanceSections(ctx))
Assert.len(rows[3], 1, "关彩色后主题色与饱和度消失")
Assert.eq(settings.theme_preset, "clay", "隐藏主题色不清除已有选择")
Assert.eq(settings.color_saturation, "max", "隐藏饱和度不清除已有选择")
rows[3][1].callback()
titles, rows = flatten(Display:appearanceSections(ctx))
Assert.eq(rows[3][2].status, "赤陶红", "重新开启沿用已选色板")
Assert.eq(rows[3][3].status, "极致", "重新开启沿用饱和度")
rows[3][1].callback()

eink, color_screen, frontlight = false, false, false
package.loaded["device"] = nil
package.loaded["desktop.pages.setting.display"] = nil
Display = require("desktop.pages.setting.display")
Assert.eq(#Display:screenRows{ desktop = {} }, 0, "无墨水屏时不展示刷新项")
titles, rows = flatten(Display:appearanceSections(ctx))
Assert.eq(table.concat(titles, ","), "风格,字体与缩放", "不支持彩色时不出彩色分节")
Assert.len(rows[1], 2)
Assert.len(rows[2], 3)
require("device").screen.isColorEnabled = nil
titles = flatten(Display:appearanceSections(ctx))
Assert.eq(table.concat(titles, ","), "风格,字体与缩放", "缺少彩色查询接口不会报错")

Assert.is_nil(rawget(Display, "inputRows"), "分页与弹窗不属于外观设置")
